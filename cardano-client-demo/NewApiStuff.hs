{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -freduction-depth=0 #-}

module NewApiStuff
  ( LedgerStateVar(..)
  , initialLedgerState
  , applyBlock
  )
  where

import           Control.Exception
import           Control.Monad.Except
import           Control.Monad.Trans.Except.Extra
import           Data.Aeson as Aeson
import           Data.ByteArray (ByteArrayAccess)
import qualified Data.ByteArray
import           Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import           Data.ByteString.Short as BSS
import           Data.Foldable
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (fromMaybe)
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Data.Word
import qualified Data.Yaml as Yaml
import           GHC.Conc
import           GHC.Natural
import           System.FilePath

import qualified Cardano.BM.Configuration.Model as BM
import qualified Cardano.BM.Data.Configuration as BM
import qualified Cardano.Chain.Genesis
import qualified Cardano.Chain.Genesis as Cardano.Chain.Genesis.Config
import qualified Cardano.Chain.Genesis as Cardano.Chain.Genesis.Data
import qualified Cardano.Chain.UTxO
import qualified Cardano.Chain.Update
import qualified Cardano.Crypto
import qualified Cardano.Crypto.Hash.Blake2b
import qualified Cardano.Crypto.Hash.Class
import qualified Cardano.Crypto.Hashing
import qualified Cardano.Crypto.ProtocolMagic
import qualified Cardano.Slotting.EpochInfo.API
import qualified Cardano.Slotting.Slot
import qualified Data.Aeson.Types as Data.Aeson.Types.Internal
import           Data.Functor.Identity (Identity (..))
import qualified Ouroboros.Consensus.Block.Abstract
import qualified Ouroboros.Consensus.BlockchainTime.WallClock.Types
import qualified Ouroboros.Consensus.Byron.Ledger.Block
import qualified Ouroboros.Consensus.Cardano
import qualified Ouroboros.Consensus.Cardano as C
import qualified Ouroboros.Consensus.Cardano.Block
import qualified Ouroboros.Consensus.Cardano.Block as C
import qualified Ouroboros.Consensus.Cardano.CanHardFork
import qualified Ouroboros.Consensus.Cardano.Node
import qualified Ouroboros.Consensus.Config
import qualified Ouroboros.Consensus.Config as C
import qualified Ouroboros.Consensus.HardFork.Combinator.AcrossEras
import qualified Ouroboros.Consensus.HardFork.Combinator.Basics
import qualified Ouroboros.Consensus.HardFork.Combinator.State
import qualified Ouroboros.Consensus.HeaderValidation
import qualified Ouroboros.Consensus.Ledger.Abstract
import qualified Ouroboros.Consensus.Ledger.Basics
import qualified Ouroboros.Consensus.Ledger.Extended
import qualified Ouroboros.Consensus.Ledger.Extended as C
import qualified Ouroboros.Consensus.Node.ProtocolInfo
import qualified Ouroboros.Consensus.Shelley.Eras
import qualified Ouroboros.Consensus.Shelley.Ledger.Block
import qualified Ouroboros.Consensus.Shelley.Ledger.Ledger
import qualified Ouroboros.Consensus.Shelley.Protocol
import qualified Ouroboros.Network.Block
import qualified Ouroboros.Network.Magic
import qualified Shelley.Spec.Ledger.API.Protocol
import qualified Shelley.Spec.Ledger.Address
import qualified Shelley.Spec.Ledger.BaseTypes
import qualified Shelley.Spec.Ledger.Coin
import qualified Shelley.Spec.Ledger.Credential
import qualified Shelley.Spec.Ledger.EpochBoundary
import qualified Shelley.Spec.Ledger.Genesis
import qualified Shelley.Spec.Ledger.Keys
import qualified Shelley.Spec.Ledger.LedgerState
import qualified Shelley.Spec.Ledger.PParams
import qualified Shelley.Spec.Ledger.STS.Tickn

-- Bring it all together and make the initial ledger state
initialLedgerState
  :: FilePath -- Path to the db-sync config file
  -> IO (DbSyncEnv, LedgerStateVar)
initialLedgerState dbSyncConfFilePath = do
  dbSyncConf <- readDbSyncNodeConfig (ConfigFile dbSyncConfFilePath)
  genConf <- fmap (either (error . Text.unpack . renderDbSyncNodeError) id) $ runExceptT (readCardanoGenesisConfig dbSyncConf)
  env <- either (error . Text.unpack . renderDbSyncNodeError) return (genesisConfigToEnv genConf)
  st0 <- initLedgerStateVar genConf
  return (env, st0)

--------------------------------------------------------------------------------
-- Everything below this is just coppied from db-sync                         --
--------------------------------------------------------------------------------

genesisConfigToEnv ::
  -- DbSyncNodeParams ->
  GenesisConfig ->
  Either DbSyncNodeError DbSyncEnv
genesisConfigToEnv
  -- enp
  genCfg =
    case genCfg of
      GenesisCardano _ bCfg sCfg
        | Cardano.Crypto.ProtocolMagic.unProtocolMagicId (Cardano.Chain.Genesis.Config.configProtocolMagicId bCfg) /= Shelley.Spec.Ledger.Genesis.sgNetworkMagic (scConfig sCfg) ->
            Left . NECardanoConfig $
              mconcat
                [ "ProtocolMagicId ", textShow (Cardano.Crypto.ProtocolMagic.unProtocolMagicId $ Cardano.Chain.Genesis.Config.configProtocolMagicId bCfg)
                , " /= ", textShow (Shelley.Spec.Ledger.Genesis.sgNetworkMagic $ scConfig sCfg)
                ]
        | Cardano.Chain.Genesis.Data.gdStartTime (Cardano.Chain.Genesis.Config.configGenesisData bCfg) /= Shelley.Spec.Ledger.Genesis.sgSystemStart (scConfig sCfg) ->
            Left . NECardanoConfig $
              mconcat
                [ "SystemStart ", textShow (Cardano.Chain.Genesis.Data.gdStartTime $ Cardano.Chain.Genesis.Config.configGenesisData bCfg)
                , " /= ", textShow (Shelley.Spec.Ledger.Genesis.sgSystemStart $ scConfig sCfg)
                ]
        | otherwise ->
            Right $ DbSyncEnv
                  { envProtocol = DbSyncProtocolCardano
                  , envNetwork = Shelley.Spec.Ledger.Genesis.sgNetworkId (scConfig sCfg)
                  , envNetworkMagic = Ouroboros.Network.Magic.NetworkMagic (Cardano.Crypto.ProtocolMagic.unProtocolMagicId $ Cardano.Chain.Genesis.Config.configProtocolMagicId bCfg)
                  , envSystemStart = Ouroboros.Consensus.BlockchainTime.WallClock.Types.SystemStart (Cardano.Chain.Genesis.Data.gdStartTime $ Cardano.Chain.Genesis.Config.configGenesisData bCfg)
                  -- , envLedgerStateDir = enpLedgerStateDir enp
                  }

newtype ConfigFile = ConfigFile
  { unConfigFile :: FilePath
  }

readDbSyncNodeConfig :: ConfigFile -> IO DbSyncNodeConfig
readDbSyncNodeConfig (ConfigFile fp) = do
    pcfg <- adjustNodeFilePath . parseDbSyncPreConfig <$> readByteString fp "DbSync"
    ncfg <- parseNodeConfig <$> readByteString (pcNodeConfigFilePath pcfg) "node"
    coalesceConfig pcfg ncfg (mkAdjustPath pcfg)
  where
    parseDbSyncPreConfig :: ByteString -> DbSyncPreConfig
    parseDbSyncPreConfig bs =
      case Yaml.decodeEither' bs of
      Left err -> error . Text.unpack $ "readDbSyncNodeConfig: Error parsing config: " <> textShow err
      Right res -> res

    adjustNodeFilePath :: DbSyncPreConfig -> DbSyncPreConfig
    adjustNodeFilePath cfg =
      cfg { pcNodeConfigFile = adjustNodeConfigFilePath (takeDirectory fp </>) (pcNodeConfigFile cfg) }


adjustNodeConfigFilePath :: (FilePath -> FilePath) -> NodeConfigFile -> NodeConfigFile
adjustNodeConfigFilePath f (NodeConfigFile p) = NodeConfigFile (f p)

pcNodeConfigFilePath :: DbSyncPreConfig -> FilePath
pcNodeConfigFilePath = unNodeConfigFile . pcNodeConfigFile

data NodeConfig = NodeConfig
  { ncProtocol :: !DbSyncProtocol
  , ncPBftSignatureThreshold :: !(Maybe Double)
  , ncByronGenesisFile :: !GenesisFile
  , ncByronGenesisHash :: !GenesisHashByron
  , ncShelleyGenesisFile :: !GenesisFile
  , ncShelleyGenesisHash :: !GenesisHashShelley
  , ncRequiresNetworkMagic :: !Cardano.Crypto.RequiresNetworkMagic
  , ncByronSotfwareVersion :: !Cardano.Chain.Update.SoftwareVersion
  , ncByronProtocolVersion :: !Cardano.Chain.Update.ProtocolVersion

  -- Shelley hardfok parameters
  , ncShelleyHardFork :: !Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
  , ncByronToShelley :: !ByronToShelley

  -- Allegra hardfok parameters
  , ncAllegraHardFork :: !Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
  , ncShelleyToAllegra :: !ShelleyToAllegra

  -- Mary hardfok parameters
  , ncMaryHardFork :: !Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
  , ncAllegraToMary :: !AllegraToMary
  }


instance FromJSON NodeConfig where
  parseJSON v =
      Aeson.withObject "NodeConfig" parse v
    where
      parse :: Object -> Data.Aeson.Types.Internal.Parser NodeConfig
      parse o =
        NodeConfig
          <$> o .: "Protocol"
          <*> o .:? "PBftSignatureThreshold"
          <*> fmap GenesisFile (o .: "ByronGenesisFile")
          <*> fmap GenesisHashByron (o .: "ByronGenesisHash")
          <*> fmap GenesisFile (o .: "ShelleyGenesisFile")
          <*> fmap GenesisHashShelley (o .: "ShelleyGenesisHash")
          <*> o .: "RequiresNetworkMagic"
          <*> parseByronSoftwareVersion o
          <*> parseByronProtocolVersion o

          <*> parseShelleyHardForkEpoch o
          <*> (Ouroboros.Consensus.Cardano.Node.ProtocolParamsTransition <$> parseShelleyHardForkEpoch o)

          <*> parseAllegraHardForkEpoch o
          <*> (Ouroboros.Consensus.Cardano.Node.ProtocolParamsTransition <$> parseAllegraHardForkEpoch o)

          <*> parseMaryHardForkEpoch o
          <*> (Ouroboros.Consensus.Cardano.Node.ProtocolParamsTransition <$> parseMaryHardForkEpoch o)

      parseByronProtocolVersion :: Object -> Data.Aeson.Types.Internal.Parser Cardano.Chain.Update.ProtocolVersion
      parseByronProtocolVersion o =
        Cardano.Chain.Update.ProtocolVersion
          <$> o .: "LastKnownBlockVersion-Major"
          <*> o .: "LastKnownBlockVersion-Minor"
          <*> o .: "LastKnownBlockVersion-Alt"

      parseByronSoftwareVersion :: Object -> Data.Aeson.Types.Internal.Parser Cardano.Chain.Update.SoftwareVersion
      parseByronSoftwareVersion o =
        Cardano.Chain.Update.SoftwareVersion
          <$> fmap Cardano.Chain.Update.ApplicationName (o .: "ApplicationName")
          <*> o .: "ApplicationVersion"

      parseShelleyHardForkEpoch :: Object -> Data.Aeson.Types.Internal.Parser Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
      parseShelleyHardForkEpoch o =
        asum
          [ Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardForkAtEpoch <$> o .: "TestShelleyHardForkAtEpoch"
          , pure $ Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardForkAtVersion 2 -- Mainnet default
          ]

      parseAllegraHardForkEpoch :: Object -> Data.Aeson.Types.Internal.Parser Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
      parseAllegraHardForkEpoch o =
        asum
          [ Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardForkAtEpoch <$> o .: "TestAllegraHardForkAtEpoch"
          , pure $ Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardForkAtVersion 3 -- Mainnet default
          ]

      parseMaryHardForkEpoch :: Object -> Data.Aeson.Types.Internal.Parser Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
      parseMaryHardForkEpoch o =
        asum
          [ Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardForkAtEpoch <$> o .: "TestMaryHardForkAtEpoch"
          , pure $ Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardForkAtVersion 4 -- Mainnet default
          ]

parseNodeConfig :: ByteString -> NodeConfig
parseNodeConfig bs =
  case Yaml.decodeEither' bs of
    Left err -> error . Text.unpack $ "Error parsing node config: " <> textShow err
    Right nc -> nc

coalesceConfig
    :: DbSyncPreConfig -> NodeConfig -> (FilePath -> FilePath)
    -> IO DbSyncNodeConfig
coalesceConfig pcfg ncfg adjustGenesisPath = do
  lc <- BM.setupFromRepresentation $ pcLoggingConfig pcfg
  pure $ DbSyncNodeConfig
          { dncNetworkName = pcNetworkName pcfg
          , dncLoggingConfig = lc
          , dncNodeConfigFile = pcNodeConfigFile pcfg
          , dncProtocol = ncProtocol ncfg
          , dncRequiresNetworkMagic = ncRequiresNetworkMagic ncfg
          , dncEnableLogging = pcEnableLogging pcfg
          , dncEnableMetrics = pcEnableMetrics pcfg
          , dncPBftSignatureThreshold = ncPBftSignatureThreshold ncfg
          , dncByronGenesisFile = adjustGenesisFilePath adjustGenesisPath (ncByronGenesisFile ncfg)
          , dncByronGenesisHash = ncByronGenesisHash ncfg
          , dncShelleyGenesisFile = adjustGenesisFilePath adjustGenesisPath (ncShelleyGenesisFile ncfg)
          , dncShelleyGenesisHash = ncShelleyGenesisHash ncfg
          , dncByronSoftwareVersion = ncByronSotfwareVersion ncfg
          , dncByronProtocolVersion = ncByronProtocolVersion ncfg

          , dncShelleyHardFork = ncShelleyHardFork ncfg
          , dncAllegraHardFork = ncAllegraHardFork ncfg
          , dncMaryHardFork = ncMaryHardFork ncfg

          , dncByronToShelley = ncByronToShelley ncfg
          , dncShelleyToAllegra = ncShelleyToAllegra ncfg
          , dncAllegraToMary = ncAllegraToMary ncfg
          }

adjustGenesisFilePath :: (FilePath -> FilePath) -> GenesisFile -> GenesisFile
adjustGenesisFilePath f (GenesisFile p) = GenesisFile (f p)

mkAdjustPath :: DbSyncPreConfig -> (FilePath -> FilePath)
mkAdjustPath cfg fp = takeDirectory (pcNodeConfigFilePath cfg) </> fp

readByteString :: FilePath -> Text -> IO ByteString
readByteString fp cfgType =
  catch (BS.readFile fp) $ \(_ :: IOException) ->
    error . Text.unpack $ mconcat [ "Cannot find the ", cfgType, " configuration file at : ", Text.pack fp ]


initLedgerStateVar :: GenesisConfig -> IO LedgerStateVar
initLedgerStateVar genesisConfig =
  fmap LedgerStateVar . newTVarIO $
    CardanoLedgerState
      { clsState = Ouroboros.Consensus.Node.ProtocolInfo.pInfoInitLedger protocolInfo
      , clsConfig = Ouroboros.Consensus.Node.ProtocolInfo.pInfoConfig protocolInfo
      }
  where
    protocolInfo = mkProtocolInfoCardano genesisConfig

data CardanoLedgerState = CardanoLedgerState
  { clsState :: !(C.ExtLedgerState (C.CardanoBlock C.StandardCrypto))
  , clsConfig :: !(C.TopLevelConfig (C.CardanoBlock C.StandardCrypto))
  }

newtype LedgerStateVar = LedgerStateVar
  { unLedgerStateVar :: TVar CardanoLedgerState
  }

-- Usually only one constructor, but may have two when we are preparing for a HFC event.
data GenesisConfig
  = GenesisCardano !DbSyncNodeConfig !Cardano.Chain.Genesis.Config !ShelleyConfig

data ShelleyConfig = ShelleyConfig
  { scConfig :: !(Shelley.Spec.Ledger.Genesis.ShelleyGenesis Ouroboros.Consensus.Shelley.Eras.StandardShelley)
  , scGenesisHash :: !GenesisHashShelley
  }


data DbSyncNodeConfig = DbSyncNodeConfig
  { dncNetworkName :: !NetworkName
  , dncLoggingConfig :: !BM.Configuration
  , dncNodeConfigFile :: !NodeConfigFile
  , dncProtocol :: !DbSyncProtocol
  , dncRequiresNetworkMagic :: !Cardano.Crypto.RequiresNetworkMagic
  , dncEnableLogging :: !Bool
  , dncEnableMetrics :: !Bool
  , dncPBftSignatureThreshold :: !(Maybe Double)
  , dncByronGenesisFile :: !GenesisFile
  , dncByronGenesisHash :: !GenesisHashByron
  , dncShelleyGenesisFile :: !GenesisFile
  , dncShelleyGenesisHash :: !GenesisHashShelley
  , dncByronSoftwareVersion :: !Cardano.Chain.Update.SoftwareVersion
  , dncByronProtocolVersion :: !Cardano.Chain.Update.ProtocolVersion

  , dncShelleyHardFork :: !Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
  , dncAllegraHardFork :: !Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork
  , dncMaryHardFork :: !Ouroboros.Consensus.Cardano.CanHardFork.TriggerHardFork

  , dncByronToShelley :: !ByronToShelley
  , dncShelleyToAllegra :: !ShelleyToAllegra
  , dncAllegraToMary :: !AllegraToMary
  }

-- May have other constructors when we are preparing for a HFC event.
data DbSyncProtocol
  = DbSyncProtocolCardano
  deriving Show

instance FromJSON DbSyncProtocol where
  parseJSON o =
    case o of
      String "Cardano" -> pure DbSyncProtocolCardano
      x -> Data.Aeson.Types.Internal.typeMismatch "Protocol" x

type ByronToShelley =
  C.ProtocolParamsTransition Ouroboros.Consensus.Byron.Ledger.Block.ByronBlock
    (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardShelley)

type ShelleyToAllegra =
  C.ProtocolParamsTransition
    (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardShelley)
    (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardAllegra)

type AllegraToMary =
  C.ProtocolParamsTransition
    (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardAllegra)
    (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardMary)

data DbSyncPreConfig = DbSyncPreConfig
  { pcNetworkName :: !NetworkName
  , pcLoggingConfig :: !BM.Representation
  , pcNodeConfigFile :: !NodeConfigFile
  , pcEnableLogging :: !Bool
  , pcEnableMetrics :: !Bool
  }

instance FromJSON DbSyncPreConfig where
  parseJSON o =
    Aeson.withObject "top-level" parseGenDbSyncNodeConfig o


parseGenDbSyncNodeConfig :: Object -> Data.Aeson.Types.Internal.Parser DbSyncPreConfig
parseGenDbSyncNodeConfig o =
  DbSyncPreConfig
    <$> fmap NetworkName (o .: "NetworkName")
    <*> parseJSON (Object o)
    <*> fmap NodeConfigFile (o .: "NodeConfigFile")
    <*> o .: "EnableLogging"
    <*> o .: "EnableLogMetrics"

newtype GenesisFile = GenesisFile
  { unGenesisFile :: FilePath
  } deriving Show

newtype GenesisHashByron = GenesisHashByron
  { unGenesisHashByron :: Text
  } deriving newtype (Eq, Show)

newtype GenesisHashShelley = GenesisHashShelley
  { unGenesisHashShelley :: Cardano.Crypto.Hash.Class.Hash Cardano.Crypto.Hash.Blake2b.Blake2b_256 ByteString
  } deriving newtype (Eq, Show)

newtype LedgerStateDir = LedgerStateDir
  {  unLedgerStateDir :: FilePath
  } deriving Show

newtype NetworkName = NetworkName
  { unNetworkName :: Text
  } deriving Show

newtype NodeConfigFile = NodeConfigFile
  { unNodeConfigFile :: FilePath
  } deriving Show

newtype SocketPath = SocketPath
  { unSocketPath :: FilePath
  } deriving Show

mkProtocolInfoCardano :: GenesisConfig -> Ouroboros.Consensus.Node.ProtocolInfo.ProtocolInfo IO CardanoBlock
mkProtocolInfoCardano = Ouroboros.Consensus.Cardano.protocolInfo . mkProtocolCardano

type CardanoBlock =
        Ouroboros.Consensus.HardFork.Combinator.Basics.HardForkBlock
            (Ouroboros.Consensus.Cardano.Block.CardanoEras C.StandardCrypto)

mkProtocolCardano :: GenesisConfig -> C.Protocol m CardanoBlock CardanoProtocol
mkProtocolCardano ge =
  case ge of
    GenesisCardano dnc byronGenesis shelleyGenesis ->
        C.ProtocolCardano
          C.ProtocolParamsByron
            { C.byronGenesis = byronGenesis
            , C.byronPbftSignatureThreshold = C.PBftSignatureThreshold <$> dncPBftSignatureThreshold dnc
            , C.byronProtocolVersion = dncByronProtocolVersion dnc
            , C.byronSoftwareVersion = dncByronSoftwareVersion dnc
            , C.byronLeaderCredentials = Nothing
            }
          C.ProtocolParamsShelleyBased
            { C.shelleyBasedGenesis = scConfig shelleyGenesis
            , C.shelleyBasedInitialNonce = shelleyPraosNonce shelleyGenesis
            , C.shelleyBasedLeaderCredentials = []
            }
          C.ProtocolParamsShelley
            { C.shelleyProtVer = shelleyProtVer dnc
            }
          C.ProtocolParamsAllegra
            { C.allegraProtVer = shelleyProtVer dnc
            }
          C.ProtocolParamsMary
            { C.maryProtVer = shelleyProtVer dnc
            }
          (dncByronToShelley dnc)
          (dncShelleyToAllegra dnc)
          (dncAllegraToMary dnc)

shelleyPraosNonce :: ShelleyConfig -> Shelley.Spec.Ledger.BaseTypes.Nonce
shelleyPraosNonce sCfg = Shelley.Spec.Ledger.BaseTypes.Nonce (Cardano.Crypto.Hash.Class.castHash . unGenesisHashShelley $ scGenesisHash sCfg)

shelleyProtVer :: DbSyncNodeConfig -> Shelley.Spec.Ledger.PParams.ProtVer
shelleyProtVer dnc =
  let bver = dncByronProtocolVersion dnc in
  Shelley.Spec.Ledger.PParams.ProtVer
    (fromIntegral $ Cardano.Chain.Update.pvMajor bver)
    (fromIntegral $ Cardano.Chain.Update.pvMinor bver)

type CardanoProtocol =
        Ouroboros.Consensus.HardFork.Combinator.Basics.HardForkProtocol
            '[ Ouroboros.Consensus.Byron.Ledger.Block.ByronBlock
            , Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardShelley
            , Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardAllegra
            , Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardMary
            ]

readCardanoGenesisConfig
        :: DbSyncNodeConfig
        -> ExceptT DbSyncNodeError IO GenesisConfig
readCardanoGenesisConfig enc =
  case dncProtocol enc of
    DbSyncProtocolCardano ->
      GenesisCardano enc <$> readByronGenesisConfig enc <*> readShelleyGenesisConfig enc

data DbSyncNodeError
  = NELookup !Text !LookupFail
  | NEError !Text
  | NEInvariant !Text !DbSyncInvariant
  | NEBlockMismatch !Word64 !ByteString !ByteString
  | NEByronConfig !FilePath !Cardano.Chain.Genesis.Config.ConfigurationError
  | NEShelleyConfig !FilePath !Text
  | NECardanoConfig !Text

renderDbSyncNodeError :: DbSyncNodeError -> Text
renderDbSyncNodeError ne =
  case ne of
    NELookup loc lf -> mconcat [ "DB lookup fail in ", loc, ": ", renderLookupFail lf ]
    NEError t -> "Error: " <> t
    NEInvariant loc i -> mconcat [ loc, ": " <> renderDbSyncInvariant i ]
    NEBlockMismatch blkNo hashDb hashBlk ->
      mconcat
        [ "Block mismatch for block number ", textShow blkNo, ", db has "
        , bsBase16Encode hashDb, " but chain provided ", bsBase16Encode hashBlk
        ]
    NEByronConfig fp ce ->
      mconcat
        [ "Failed reading Byron genesis file ", textShow fp, ": ", textShow ce
        ]
    NEShelleyConfig fp txt ->
      mconcat
        [ "Failed reading Shelley genesis file ", textShow fp, ": ", txt
        ]
    NECardanoConfig err ->
      mconcat
        [ "With Cardano protocol, Byron/Shelley config mismatch:\n"
        , "   ", err
        ]

unTxHash :: Cardano.Crypto.Hashing.Hash Cardano.Chain.UTxO.Tx -> ByteString
unTxHash =  Cardano.Crypto.Hashing.abstractHashToBytes

renderDbSyncInvariant :: DbSyncInvariant -> Text
renderDbSyncInvariant ei =
  case ei of
    EInvInOut inval outval ->
      mconcat [ "input value ", textShow inval, " < output value ", textShow outval ]
    EInvTxInOut tx inval outval ->
      mconcat
        [ "tx ", bsBase16Encode (unTxHash $ Cardano.Crypto.Hashing.serializeCborHash tx)
        , " : input value ", textShow inval, " < output value ", textShow outval
        , "\n", textShow tx
        ]

bsBase16Encode :: ByteString -> Text
bsBase16Encode bs =
  case Text.decodeUtf8' (Base16.encode bs) of
    Left _ -> Text.pack $ "UTF-8 decode failed for " ++ show bs
    Right txt -> txt

renderLookupFail :: LookupFail -> Text
renderLookupFail lf =
  case lf of
    DbLookupBlockHash h -> "block hash " <> base16encode h
    DbLookupBlockId blkid -> "block id " <> textShow blkid
    DbLookupMessage txt -> txt
    DbLookupTxHash h -> "tx hash " <> base16encode h
    DbLookupTxOutPair h i ->
        Text.concat [ "tx out pair (", base16encode h, ", ", textShow i, ")" ]
    DbLookupEpochNo e ->
        Text.concat [ "epoch number ", textShow e ]
    DbLookupSlotNo s ->
        Text.concat [ "slot number ", textShow s ]
    DbMetaEmpty -> "Meta table is empty"
    DbMetaMultipleRows -> "Multiple rows in Meta table which should only contain one"

base16encode :: ByteString -> Text
base16encode = Text.decodeUtf8 . Base16.encode

data LookupFail
  = DbLookupBlockHash !ByteString
  | DbLookupBlockId !Word64
  | DbLookupMessage !Text
  | DbLookupTxHash !ByteString
  | DbLookupTxOutPair !ByteString !Word16
  | DbLookupEpochNo !Word64
  | DbLookupSlotNo !Word64
  | DbMetaEmpty
  | DbMetaMultipleRows
  deriving (Eq, Show)

data DbSyncInvariant
  = EInvInOut !Word64 !Word64
  | EInvTxInOut !Cardano.Chain.UTxO.Tx !Word64 !Word64

readByronGenesisConfig
        :: DbSyncNodeConfig
        -> ExceptT DbSyncNodeError IO Cardano.Chain.Genesis.Config.Config
readByronGenesisConfig enc = do
  let file = unGenesisFile $ dncByronGenesisFile enc
  genHash <- firstExceptT NEError
                . hoistEither
                $ Cardano.Crypto.Hashing.decodeAbstractHash (unGenesisHashByron $ dncByronGenesisHash enc)
  firstExceptT (NEByronConfig file)
                $ Cardano.Chain.Genesis.Config.mkConfigFromFile (dncRequiresNetworkMagic enc) file genHash


readShelleyGenesisConfig
    :: DbSyncNodeConfig
    -> ExceptT DbSyncNodeError IO ShelleyConfig
readShelleyGenesisConfig enc = do
  let file = unGenesisFile $ dncShelleyGenesisFile enc
  firstExceptT (NEShelleyConfig file . renderShelleyGenesisError)
    $ readGenesis (GenesisFile file) Nothing

textShow :: Show a => a -> Text
textShow = Text.pack . show

readGenesis
    :: GenesisFile -> Maybe GenesisHashShelley
    -> ExceptT ShelleyGenesisError IO ShelleyConfig
readGenesis (GenesisFile file) mbExpectedGenesisHash = do
    content <- handleIOExceptT (GenesisReadError file . textShow) $ BS.readFile file
    let genesisHash = GenesisHashShelley (Cardano.Crypto.Hash.Class.hashWith id content)
    checkExpectedGenesisHash genesisHash
    genesis <- firstExceptT (GenesisDecodeError file . Text.pack)
                  . hoistEither
                  $ Aeson.eitherDecodeStrict' content
    pure $ ShelleyConfig genesis genesisHash
  where
    checkExpectedGenesisHash :: GenesisHashShelley -> ExceptT ShelleyGenesisError IO ()
    checkExpectedGenesisHash actual =
      case mbExpectedGenesisHash of
        Just expected | actual /= expected
          -> left (GenesisHashMismatch actual expected)
        _ -> pure ()

data ShelleyGenesisError
     = GenesisReadError !FilePath !Text
     | GenesisHashMismatch !GenesisHashShelley !GenesisHashShelley -- actual, expected
     | GenesisDecodeError !FilePath !Text
     deriving Show

renderShelleyGenesisError :: ShelleyGenesisError -> Text
renderShelleyGenesisError sge =
    case sge of
      GenesisReadError fp err ->
        mconcat
          [ "There was an error reading the genesis file: ", Text.pack fp
          , " Error: ", err
          ]

      GenesisHashMismatch actual expected ->
        mconcat
          [ "Wrong Shelley genesis file: the actual hash is ", renderHash actual
          , ", but the expected Shelley genesis hash given in the node "
          , "configuration file is ", renderHash expected, "."
          ]

      GenesisDecodeError fp err ->
        mconcat
          [ "There was an error parsing the genesis file: ", Text.pack fp
          , " Error: ", err
          ]
  where
    renderHash :: GenesisHashShelley -> Text
    renderHash (GenesisHashShelley h) = Text.decodeUtf8 $ Base16.encode (Cardano.Crypto.Hash.Class.hashToBytes h)



data ProtoParams = ProtoParams
  { ppMinfeeA :: !Natural
  , ppMinfeeB :: !Natural
  , ppMaxBBSize :: !Natural
  , ppMaxTxSize :: !Natural
  , ppMaxBHSize :: !Natural
  , ppKeyDeposit :: !Shelley.Spec.Ledger.Coin.Coin
  , ppPoolDeposit :: !Shelley.Spec.Ledger.Coin.Coin
  , ppMaxEpoch :: !Cardano.Slotting.Slot.EpochNo
  , ppOptialPoolCount :: !Natural
  , ppInfluence :: !Rational
  , ppMonetaryExpandRate :: !Shelley.Spec.Ledger.BaseTypes.UnitInterval
  , ppTreasuryGrowthRate :: !Shelley.Spec.Ledger.BaseTypes.UnitInterval
  , ppDecentralisation :: !Shelley.Spec.Ledger.BaseTypes.UnitInterval
  , ppExtraEntropy :: !Shelley.Spec.Ledger.BaseTypes.Nonce
  , ppProtocolVersion :: !Shelley.Spec.Ledger.PParams.ProtVer
  , ppMinUTxOValue :: !Shelley.Spec.Ledger.Coin.Coin
  , ppMinPoolCost :: !Shelley.Spec.Ledger.Coin.Coin
  }

-- The `ledger-specs` code defines a `RewardUpdate` type that is parameterised over
-- Shelley/Allegra/Mary. This is a huge pain in the neck for `db-sync` so we define a
-- generic one instead.
newtype Rewards
  = Rewards { unRewards :: Map StakeCred Shelley.Spec.Ledger.Coin.Coin }

newtype StakeCred
  = StakeCred { unStakeCred :: ByteString }
  deriving (Eq, Ord)

newtype StakeDist
  = StakeDist { unStakeDist :: Map StakeCred Shelley.Spec.Ledger.Coin.Coin }

data EpochUpdate = EpochUpdate
  { euProtoParams :: !ProtoParams
  , euRewards :: !(Maybe Rewards)
  , euStakeDistribution :: !StakeDist
  , euNonce :: !Shelley.Spec.Ledger.BaseTypes.Nonce
  }


allegraEpochUpdate
  :: DbSyncEnv
  -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardAllegra)
  -> Maybe Rewards
  -> Maybe Shelley.Spec.Ledger.BaseTypes.Nonce
  -> EpochUpdate
allegraEpochUpdate env sls mRewards mNonce =
  EpochUpdate
    { euProtoParams = allegraProtoParams sls
    , euRewards = mRewards
    , euStakeDistribution = allegraStakeDist env sls
    , euNonce = fromMaybe Shelley.Spec.Ledger.BaseTypes.NeutralNonce mNonce
    }

allegraStakeDist :: DbSyncEnv -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardAllegra) -> StakeDist
allegraStakeDist env
  = StakeDist
  . Map.mapKeys (toStakeCred env)
  . Shelley.Spec.Ledger.EpochBoundary.unStake
  . Shelley.Spec.Ledger.EpochBoundary._stake
  . Shelley.Spec.Ledger.EpochBoundary._pstakeSet
  . Shelley.Spec.Ledger.LedgerState.esSnapshots
  . Shelley.Spec.Ledger.LedgerState.nesEs
  . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

maryStakeDist :: DbSyncEnv -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardMary) -> StakeDist
maryStakeDist env
  = StakeDist
  . Map.mapKeys (toStakeCred env)
  . Shelley.Spec.Ledger.EpochBoundary.unStake
  . Shelley.Spec.Ledger.EpochBoundary._stake
  . Shelley.Spec.Ledger.EpochBoundary._pstakeSet
  . Shelley.Spec.Ledger.LedgerState.esSnapshots
  . Shelley.Spec.Ledger.LedgerState.nesEs
  . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

shelleyStakeDist :: DbSyncEnv -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardShelley) -> StakeDist
shelleyStakeDist env
  = StakeDist
  . Map.mapKeys (toStakeCred env)
  . Shelley.Spec.Ledger.EpochBoundary.unStake
  . Shelley.Spec.Ledger.EpochBoundary._stake
  . Shelley.Spec.Ledger.EpochBoundary._pstakeSet
  . Shelley.Spec.Ledger.LedgerState.esSnapshots
  . Shelley.Spec.Ledger.LedgerState.nesEs
  . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

allegraRewards
  :: DbSyncEnv
  -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardAllegra)
  -> Maybe Rewards
allegraRewards env
  = fmap (Rewards . Map.mapKeys (toStakeCred env) . Shelley.Spec.Ledger.LedgerState.rs)
  . Shelley.Spec.Ledger.BaseTypes.strictMaybeToMaybe
  . Shelley.Spec.Ledger.LedgerState.nesRu
  . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

maryRewards
  :: DbSyncEnv
  -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardMary)
  -> Maybe Rewards
maryRewards env
  = fmap (Rewards . Map.mapKeys (toStakeCred env) . Shelley.Spec.Ledger.LedgerState.rs)
  . Shelley.Spec.Ledger.BaseTypes.strictMaybeToMaybe
  . Shelley.Spec.Ledger.LedgerState.nesRu
  . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

shelleyRewards
  :: DbSyncEnv
  -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardShelley)
  -> Maybe Rewards
shelleyRewards env
  = fmap (Rewards . Map.mapKeys (toStakeCred env) . Shelley.Spec.Ledger.LedgerState.rs)
  . Shelley.Spec.Ledger.BaseTypes.strictMaybeToMaybe
  . Shelley.Spec.Ledger.LedgerState.nesRu
  . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

toStakeCred :: DbSyncEnv -> Shelley.Spec.Ledger.Credential.Credential 'Shelley.Spec.Ledger.Keys.Staking era -> StakeCred
toStakeCred env cred
  = StakeCred
  $ Shelley.Spec.Ledger.Address.serialiseRewardAcnt
  $ Shelley.Spec.Ledger.Address.RewardAcnt (envNetwork env) cred

maryEpochUpdate
  :: DbSyncEnv
  -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardMary)
  -> Maybe Rewards
  -> Maybe Shelley.Spec.Ledger.BaseTypes.Nonce
  -> EpochUpdate
maryEpochUpdate env sls mRewards mNonce =
  EpochUpdate
    { euProtoParams = maryProtoParams sls
    , euRewards = mRewards
    , euStakeDistribution = maryStakeDist env sls
    , euNonce = fromMaybe Shelley.Spec.Ledger.BaseTypes.NeutralNonce mNonce
    }

shelleyEpochUpdate
  :: DbSyncEnv
  -> Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardShelley)
  -> Maybe Rewards
  -> Maybe Shelley.Spec.Ledger.BaseTypes.Nonce -> EpochUpdate
shelleyEpochUpdate env sls mRewards mNonce =
  EpochUpdate
    { euProtoParams = shelleyProtoParams sls
    , euRewards = mRewards
    , euStakeDistribution = shelleyStakeDist env sls
    , euNonce = fromMaybe Shelley.Spec.Ledger.BaseTypes.NeutralNonce mNonce
    }

allegraProtoParams :: Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardAllegra) -> ProtoParams
allegraProtoParams =
  toProtoParams . Shelley.Spec.Ledger.LedgerState.esPp . Shelley.Spec.Ledger.LedgerState.nesEs . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

maryProtoParams :: Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardMary) -> ProtoParams
maryProtoParams =
  toProtoParams . Shelley.Spec.Ledger.LedgerState.esPp . Shelley.Spec.Ledger.LedgerState.nesEs . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState

shelleyProtoParams :: Ouroboros.Consensus.Ledger.Basics.LedgerState (Ouroboros.Consensus.Shelley.Ledger.Block.ShelleyBlock Ouroboros.Consensus.Shelley.Eras.StandardShelley) -> ProtoParams
shelleyProtoParams =
  toProtoParams . Shelley.Spec.Ledger.LedgerState.esPp . Shelley.Spec.Ledger.LedgerState.nesEs . Ouroboros.Consensus.Shelley.Ledger.Ledger.shelleyLedgerState


toProtoParams :: Shelley.Spec.Ledger.PParams.PParams' Identity era -> ProtoParams
toProtoParams params =
  ProtoParams
    { ppMinfeeA = Shelley.Spec.Ledger.PParams._minfeeA params
    , ppMinfeeB = Shelley.Spec.Ledger.PParams._minfeeB params
    , ppMaxBBSize = Shelley.Spec.Ledger.PParams._maxBBSize params
    , ppMaxTxSize = Shelley.Spec.Ledger.PParams._maxTxSize params
    , ppMaxBHSize = Shelley.Spec.Ledger.PParams._maxBHSize params
    , ppKeyDeposit = Shelley.Spec.Ledger.PParams._keyDeposit params
    , ppPoolDeposit = Shelley.Spec.Ledger.PParams._poolDeposit params
    , ppMaxEpoch = Shelley.Spec.Ledger.PParams._eMax params
    , ppOptialPoolCount = Shelley.Spec.Ledger.PParams._nOpt params
    , ppInfluence = Shelley.Spec.Ledger.PParams._a0 params
    , ppMonetaryExpandRate = Shelley.Spec.Ledger.PParams._rho params
    , ppTreasuryGrowthRate = Shelley.Spec.Ledger.PParams._tau params
    , ppDecentralisation  = Shelley.Spec.Ledger.PParams._d params
    , ppExtraEntropy = Shelley.Spec.Ledger.PParams._extraEntropy params
    , ppProtocolVersion = Shelley.Spec.Ledger.PParams._protocolVersion params
    , ppMinUTxOValue = Shelley.Spec.Ledger.PParams._minUTxOValue params
    , ppMinPoolCost = Shelley.Spec.Ledger.PParams._minPoolCost params
    }

data LedgerStateSnapshot = LedgerStateSnapshot
  { lssState :: !CardanoLedgerState
  , lssEpochUpdate :: !(Maybe EpochUpdate) -- Only Just for a single block at the epoch boundary
  }

data DbSyncEnv = DbSyncEnv
  { envProtocol :: !DbSyncProtocol
  , envNetwork :: !Shelley.Spec.Ledger.BaseTypes.Network
  , envNetworkMagic :: !Ouroboros.Network.Magic.NetworkMagic
  , envSystemStart :: !Ouroboros.Consensus.BlockchainTime.WallClock.Types.SystemStart
  -- , envLedgerStateDir :: !LedgerStateDir
  }

-- The function 'tickThenReapply' does zero validation, so add minimal validation ('blockPrevHash'
-- matches the tip hash of the 'LedgerState'). This was originally for debugging but the check is
-- cheap enough to keep.
applyBlock
  :: DbSyncEnv
  -> LedgerStateVar
  -> Ouroboros.Consensus.Cardano.Block.CardanoBlock Ouroboros.Consensus.Shelley.Eras.StandardCrypto
  -> IO LedgerStateSnapshot
applyBlock env (LedgerStateVar stateVar) blk =
    -- 'LedgerStateVar' is just being used as a mutable variable. There should not ever
    -- be any contention on this variable, so putting everything inside 'atomically'
    -- is fine.
    atomically $ do
      oldState <- readTVar stateVar
      let !newState = oldState { clsState = applyBlk (C.ExtLedgerCfg (clsConfig oldState)) blk (clsState oldState) }
      writeTVar stateVar newState
      pure $ LedgerStateSnapshot
                { lssState = newState
                , lssEpochUpdate =
                    if ledgerEpochNo newState == ledgerEpochNo oldState + 1
                      then ledgerEpochUpdate env (clsState newState)
                             (ledgerRewardUpdate env (Ouroboros.Consensus.Ledger.Extended.ledgerState $ clsState oldState))
                      else Nothing
                }
  where
    applyBlk
        :: C.ExtLedgerCfg (C.CardanoBlock C.StandardCrypto) -> C.CardanoBlock C.StandardCrypto
        -> C.ExtLedgerState (C.CardanoBlock C.StandardCrypto)
        -> C.ExtLedgerState (C.CardanoBlock C.StandardCrypto)
    applyBlk cfg block lsb =
      case tickThenReapplyCheckHash cfg block lsb of
        Left err -> error $ Text.unpack err
        Right result -> result

-- This will return a 'Just' from the time the rewards are updated until the end of the
-- epoch. It is 'Nothing' for the first block of a new epoch (which is slightly inconvenient).
ledgerRewardUpdate :: DbSyncEnv -> Ouroboros.Consensus.Ledger.Basics.LedgerState (C.CardanoBlock C.StandardCrypto) -> Maybe Rewards
ledgerRewardUpdate env lsc =
    case lsc of
      Ouroboros.Consensus.Cardano.Block.LedgerStateByron _ -> Nothing -- This actually happens during the Byron era.
      Ouroboros.Consensus.Cardano.Block.LedgerStateShelley sls -> shelleyRewards env sls
      Ouroboros.Consensus.Cardano.Block.LedgerStateAllegra als -> allegraRewards env als
      Ouroboros.Consensus.Cardano.Block.LedgerStateMary mls -> maryRewards env mls

-- Create an EpochUpdate from the current epoch state and the rewards from the last epoch.
ledgerEpochUpdate :: DbSyncEnv -> C.ExtLedgerState (C.CardanoBlock C.StandardCrypto) -> Maybe Rewards -> Maybe EpochUpdate
ledgerEpochUpdate env els mRewards =
  case Ouroboros.Consensus.Ledger.Extended.ledgerState els of
    Ouroboros.Consensus.Cardano.Block.LedgerStateByron _ -> Nothing
    Ouroboros.Consensus.Cardano.Block.LedgerStateShelley sls -> Just $ shelleyEpochUpdate env sls mRewards mNonce
    Ouroboros.Consensus.Cardano.Block.LedgerStateAllegra als -> Just $ allegraEpochUpdate env als mRewards mNonce
    Ouroboros.Consensus.Cardano.Block.LedgerStateMary mls -> Just $ maryEpochUpdate env mls mRewards mNonce
  where
    mNonce :: Maybe Shelley.Spec.Ledger.BaseTypes.Nonce
    mNonce = extractEpochNonce els

extractEpochNonce :: Ouroboros.Consensus.Ledger.Extended.ExtLedgerState (C.CardanoBlock era) -> Maybe Shelley.Spec.Ledger.BaseTypes.Nonce
extractEpochNonce extLedgerState =
    case Ouroboros.Consensus.HeaderValidation.headerStateChainDep (Ouroboros.Consensus.Ledger.Extended.headerState extLedgerState) of
      Ouroboros.Consensus.Cardano.Block.ChainDepStateByron _ -> Nothing
      Ouroboros.Consensus.Cardano.Block.ChainDepStateShelley st -> Just $ extractNonce st
      Ouroboros.Consensus.Cardano.Block.ChainDepStateAllegra st -> Just $ extractNonce st
      Ouroboros.Consensus.Cardano.Block.ChainDepStateMary st -> Just $ extractNonce st
  where
    extractNonce :: Ouroboros.Consensus.Shelley.Protocol.TPraosState crypto -> Shelley.Spec.Ledger.BaseTypes.Nonce
    extractNonce
      = Shelley.Spec.Ledger.STS.Tickn.ticknStateEpochNonce
      . Shelley.Spec.Ledger.API.Protocol.csTickn
      . Ouroboros.Consensus.Shelley.Protocol.tpraosStateChainDepState


ledgerEpochNo :: CardanoLedgerState -> Cardano.Slotting.Slot.EpochNo
ledgerEpochNo cls =
    case Ouroboros.Consensus.Ledger.Abstract.ledgerTipSlot (Ouroboros.Consensus.Ledger.Extended.ledgerState (clsState cls)) of
      Cardano.Slotting.Slot.Origin -> 0 -- An empty chain is in epoch 0
      Ouroboros.Consensus.Block.Abstract.NotOrigin slot -> runIdentity $ Cardano.Slotting.EpochInfo.API.epochInfoEpoch epochInfo slot
  where
    epochInfo :: Cardano.Slotting.EpochInfo.API.EpochInfo Identity
    epochInfo = Ouroboros.Consensus.HardFork.Combinator.State.epochInfoLedger
      (Ouroboros.Consensus.Config.configLedger $ clsConfig cls)
      (Ouroboros.Consensus.HardFork.Combinator.Basics.hardForkLedgerStatePerEra . Ouroboros.Consensus.Ledger.Extended.ledgerState $ clsState cls)

-- Like 'Consensus.tickThenReapply' but also checks that the previous hash from the block matches
-- the head hash of the ledger state.
tickThenReapplyCheckHash
    :: C.ExtLedgerCfg (C.CardanoBlock C.StandardCrypto) -> C.CardanoBlock C.StandardCrypto
    -> C.ExtLedgerState (C.CardanoBlock C.StandardCrypto)
    -> Either Text (C.ExtLedgerState (C.CardanoBlock C.StandardCrypto))
tickThenReapplyCheckHash cfg block lsb =
  if Ouroboros.Consensus.Block.Abstract.blockPrevHash block == Ouroboros.Consensus.Ledger.Abstract.ledgerTipHash (Ouroboros.Consensus.Ledger.Extended.ledgerState lsb)
    then Right $ Ouroboros.Consensus.Ledger.Abstract.tickThenReapply cfg block lsb
    else Left $ mconcat
                  [ "Ledger state hash mismatch. Ledger head is slot "
                  , textShow
                      $ Cardano.Slotting.Slot.unSlotNo
                      $ Cardano.Slotting.Slot.fromWithOrigin
                          (Cardano.Slotting.Slot.SlotNo 0)
                          (Ouroboros.Consensus.Ledger.Abstract.ledgerTipSlot $ Ouroboros.Consensus.Ledger.Extended.ledgerState lsb)
                  , " hash "
                  , renderByteArray
                      $ unChainHash
                      $ Ouroboros.Consensus.Ledger.Abstract.ledgerTipHash
                      $ Ouroboros.Consensus.Ledger.Extended.ledgerState lsb
                  , " but block previous hash is "
                  , renderByteArray (unChainHash $ Ouroboros.Consensus.Block.Abstract.blockPrevHash block)
                  , " and block current hash is "
                  , renderByteArray
                      $ BSS.fromShort
                      $ Ouroboros.Consensus.HardFork.Combinator.AcrossEras.getOneEraHash
                      $ Ouroboros.Network.Block.blockHash block
                  , "."
                  ]

renderByteArray :: ByteArrayAccess bin => bin -> Text
renderByteArray =
  Text.decodeUtf8 . Base16.encode . Data.ByteArray.convert

unChainHash :: Ouroboros.Network.Block.ChainHash (C.CardanoBlock era) -> ByteString
unChainHash ch =
  case ch of
    Ouroboros.Network.Block.GenesisHash -> "genesis"
    Ouroboros.Network.Block.BlockHash bh -> BSS.fromShort (Ouroboros.Consensus.HardFork.Combinator.AcrossEras.getOneEraHash bh)


