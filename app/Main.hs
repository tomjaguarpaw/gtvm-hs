{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import           Config
import qualified CLI as CLI

import qualified GTVM.Assorted.SL01         as GAS
import qualified GTVM.Assorted.Flowchart    as GAFc
import qualified GTVM.Assorted.Pak          as GAP
import qualified GTVM.Common.Binary.Parse   as GCBP
import qualified GTVM.Common.Binary         as GCB
import qualified GTVM.SCP.Parse             as GSP
import qualified GTVM.SCP.Serialize         as GSS
import qualified BinaryPatch                as BP
import qualified BinaryPatch.Pretty         as BPP
import           BinaryPatch.JSON()
import           HexByteString
import qualified CSV                      as CSV

import qualified Data.Aeson                 as Aeson
import qualified Data.Aeson.Encode.Pretty   as DAEP
import qualified Data.Yaml                  as Yaml
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString            as BS
import qualified Data.Text                  as Text
import qualified Data.Text.Encoding         as Text
import           Data.Text                  ( Text )
import qualified Data.List                  as List
import qualified System.Exit                as Exit

import           Control.Monad.IO.Class

import qualified System.FilePath.Find       as Filemanip

main :: IO ()
main = CLI.parseOpts >>= runCmd

runCmd :: ToolGroup -> IO ()
runCmd = \case
  TGSCP cfg cS2 -> runCmdSCP cS2 cfg
  TGSL01 cfg cS2 -> runCmdSL01 cS2 cfg
  TGFlowchart cfg cS2 parseType -> runCmdFlowchart cS2 parseType cfg
  TGPak cfg cPrintStdout -> runCmdPak cPrintStdout cfg
  TGPatch cfg fpFrom cS2 cPrintStdout cPatchType cPatchFormat -> runCmdPatch cfg fpFrom cS2 cPrintStdout cPatchType cPatchFormat
  TGCSVPatch cS2 -> runCmdCSV cS2

runCmdCSV :: MonadIO m => (CStream, CStream) -> m ()
runCmdCSV (cSFrom, cSTo) = do
    bs <- rReadStream' cSFrom
    case CSV.csvDecode bs of
      Left err -> liftIO $ print err
      Right csv -> do
        let sr = CSV.csvToTextReplace <$> csv
        rWriteStreamBin True cSTo (Yaml.encode sr)

runCmdPatch
    :: MonadIO m
    => BP.Cfg -> FilePath -> (CStream, CStream) -> Bool -> CPatchType -> CPatchFormat
    -> m ()
runCmdPatch cPatch fpFrom xs cPrintStdout cPatchType cPatchFormat = do
    case cPatchFormat of
      CPatchFormatFull ->
        case cPatchType of
          CPatchTypeBin -> do
            patch <- rReadFile fpFrom >>= rForceParseYAML @([BPP.MultiPatches HexByteString])
            let (patch', errors) = (BPP.listAlgebraConcatEtc . BPP.applyBaseOffset) patch
            case errors of
              [] -> runCmdPatch' cPatch xs cPrintStdout patch'
              _  -> do
                liftIO $ putStrLn "offset error boyo"
                liftIO $ print errors
          CPatchTypeText -> do
            patch <- rReadFile fpFrom >>= rForceParseYAML @([BPP.MultiPatches Text])
            let (patch', errors) = (BPP.listAlgebraConcatEtc . BPP.applyBaseOffset) patch
            case errors of
              [] -> runCmdPatch' cPatch xs cPrintStdout patch'
              _  -> do
                liftIO $ putStrLn "offset error boyo"
                liftIO $ print errors
      CPatchFormatPlain ->
        case cPatchType of
          CPatchTypeBin -> do
            patch <- rReadFile fpFrom >>= rForceParseYAML @([BPP.MultiPatch HexByteString])
            runCmdPatch' cPatch xs cPrintStdout patch
          CPatchTypeText -> do
            patch <- rReadFile fpFrom >>= rForceParseYAML @([BPP.MultiPatch Text])
            runCmdPatch' cPatch xs cPrintStdout patch

runCmdPatch'
    :: (BPP.ToBinPatch a, MonadIO m) => BP.Cfg -> (CStream, CStream) -> Bool -> [BPP.MultiPatch a] -> m ()
runCmdPatch' cPatch (cSFrom, cSTo) cPrintStdout patch = do
    case BPP.normalize patch of
      Nothing -> liftIO $ print "script normalization error (TODO)"
      Just patches -> do
        case BP.genPatchScript patches of
          Left errorsGen -> liftIO $ print errorsGen
          Right patchScript -> do
            bsFrom <- rReadStream cSFrom
            case BP.patch patchScript bsFrom cPatch of
              Left err   -> liftIO $ print err
              Right bsTo -> rWriteStreamBin cPrintStdout cSTo bsTo

runCmdSCP :: MonadIO m => (CStream, CStream) -> CJSON -> m ()
runCmdSCP (cSFrom, cSTo) = \case
  CJSONDe cPrettify -> do
    bs <- rParseStream (fromOrig cPrettify) cSFrom
    rWriteStreamBin True cSTo bs
  CJSONEn cPrintStdout -> do
    bs <- rReadStream cSFrom
    scp <- rForceParseJSON bs
    let scpBytes = GSS.sSCP scp GCB.binCfgSCP
    rWriteStreamBin cPrintStdout cSTo scpBytes
  where
    fromOrig cPrettify fp bs = rEncodeJSON cPrettify <$> GCBP.parseBin GSP.pSCP GCB.binCfgSCP fp bs

runCmdSL01 :: MonadIO m => (CStream, CStream) -> CBin -> m ()
runCmdSL01 (cSFrom, cSTo) (CBin cDir cPrintStdout) = readBytes cDir >>= writeBytes
  where
    readBytes = \case
      CDirectionFromOrig -> rParseStream fromOrig cSFrom
      CDirectionToOrig   -> do
        bytes <- rReadStream cSFrom
        return $ GAS.sSL01 (GAS.compress bytes) GCB.binCfgSCP
    writeBytes = rWriteStreamBin cPrintStdout cSTo
    fromOrig fp bs = do
        sl01 <- GCBP.parseBin GAS.pSL01 GCB.binCfgSCP fp bs
        return $ GAS.decompress sl01

runCmdFlowchart :: (MonadIO m) => (CStream, CStream) -> CParseType -> CJSON -> m ()
runCmdFlowchart (cSFrom, cSTo) parseType = \case
  CJSONDe cPrettify -> do
    bs <- rParseStream (fromOrig cPrettify) cSFrom
    rWriteStreamBin True cSTo bs
  CJSONEn cPrintStdout -> do
    bs <- rReadStream cSFrom
    fc <- rGetFc bs parseType
    let fcBytes = GAFc.sFlowchart fc GCB.binCfgSCP
    rWriteStreamBin cPrintStdout cSTo fcBytes
  where
    fromOrig cPrettify fp bs = do
        fc <- GCBP.parseBin GAFc.pFlowchart GCB.binCfgSCP fp bs
        case parseType of
          CParseTypeFull    -> return $ rEncodeJSON cPrettify (GAFc.fcToAltFc fc)
          CParseTypePartial -> return $ rEncodeJSON cPrettify fc
    rGetFc bs = \case
      CParseTypeFull    -> GAFc.altFcToFc <$> rForceParseJSON bs
      CParseTypePartial ->                    rForceParseJSON bs

runCmdPak :: (MonadIO m) => Bool -> CPak -> m ()
runCmdPak cPrintStdout = \case
  CPakUnpack (cS1, cSN) -> do
    pak <- rParseStream parseAndExtract cS1
    case cSN of
      CStreamsArchive fp -> do
        liftIO $ putStrLn $ "error: unimplemented: write pak to archive: " <> fp
        liftIO $ Exit.exitWith (Exit.ExitFailure 3)
      CStreamsFolder  fp -> rWritePakFolder pak fp
  CPakPack (cS1, cSN) unk -> do
    case cSN of
      CStreamsArchive fp -> do
        liftIO $ putStrLn $ "error: unimplemented: write pak from archive: " <> fp
        liftIO $ Exit.exitWith (Exit.ExitFailure 3)
      CStreamsFolder  fp -> do
        files <- liftIO $ getDirContentsWithFilenameRecursive fp
        let pak = GAP.Pak unk files
            pakBytes = GAP.sPak pak GCB.binCfgSCP
        rWriteStreamBin cPrintStdout cS1 pakBytes
  where
    parseAndExtract :: FilePath -> BS.ByteString -> Either String GAP.Pak
    parseAndExtract fp bs = do
        pakHeader <- GCBP.parseBin GAP.pPakHeader GCB.binCfgSCP fp bs
        return $ pakExtract bs pakHeader

-- TODO: bad. decoding may fail, that's why we gotta do this.
rForceParseJSON :: (MonadIO m, Aeson.FromJSON a) => BS.ByteString -> m a
rForceParseJSON bs =
    case Aeson.eitherDecode (BL.fromStrict bs) of
      Left err      -> do
        liftIO $ putStrLn $ "error decoding JSON: " <> err
        liftIO $ Exit.exitWith (Exit.ExitFailure 1)
      Right decoded -> return decoded

-- TODO: bad. decoding may fail, that's why we gotta do this.
rForceParseYAML :: forall a m. (MonadIO m, Aeson.FromJSON a) => BS.ByteString -> m a
rForceParseYAML bs =
    case Yaml.decodeEither' bs of
      Left err      -> do
        liftIO $ putStrLn $ "error decoding YAML: "
        liftIO $ print err
        liftIO $ Exit.exitWith (Exit.ExitFailure 1)
      Right decoded -> return decoded

-- Only gets stuff with content (files).
getDirContentsWithFilenameRecursive :: FilePath -> IO [(Text, BS.ByteString)]
getDirContentsWithFilenameRecursive fp = do
    fileList <- Filemanip.find (pure True) (Filemanip.fileType Filemanip.==? Filemanip.RegularFile) fp
    mapM f fileList
  where
    f fp' = do
        bs <- BS.readFile fp'
        let Just fp'' = List.stripPrefix (fp <> "/") fp'
        return (Text.pack fp'', bs)

pakExtract :: BS.ByteString -> GAP.PakHeader -> GAP.Pak
pakExtract bs (GAP.PakHeader unk ft) = GAP.Pak unk (pakExtractFile bs <$> ft)

pakExtractFile :: BS.ByteString -> GAP.PakHeaderFTE -> (Text, BS.ByteString)
pakExtractFile bs (GAP.PakHeaderFTE offset len filenameBS) =
    let fileBs   = bsExtract (fromIntegral offset) (fromIntegral len) bs
        filename = Text.decodeUtf8 filenameBS
     in (filename, fileBs)

-- | Extract a indexed substring from a bytestring. Runtime error if can't.
bsExtract :: Int -> Int -> BS.ByteString -> BS.ByteString
bsExtract offset len bs =
    let bs' = (BS.take len . BS.drop offset) bs
     in if   BS.length bs' /= len
        then error "ya bytes fucked"
        else bs'

rWriteStreamBin :: MonadIO m => Bool -> CStream -> BS.ByteString -> m ()
rWriteStreamBin printStdout s bs =
    case s of
      CStreamFile fp -> liftIO $ BS.writeFile fp bs
      CStreamStd     ->
        case printStdout of
          True -> liftIO $ BS.putStr bs
          False -> do
            liftIO $ putStrLn "warning: refusing to print binary to stdout"
            liftIO $ putStrLn "(write to a file with --out-file FILE, or use --print-binary flag to override)"

rEncodeJSON :: Aeson.ToJSON a => Bool -> a -> BS.ByteString
rEncodeJSON prettify =
    case prettify of
      True  -> BL.toStrict . DAEP.encodePretty' prettyCfg
      False -> BL.toStrict . Aeson.encode
  where
    prettyCfg = DAEP.defConfig
      { DAEP.confIndent = DAEP.Spaces 2
      , DAEP.confTrailingNewline = True }

-- TODO: bad error...
rParseStream :: MonadIO m => (FilePath -> BS.ByteString -> Either String a) -> CStream -> m a
rParseStream f = \case
  CStreamFile fp -> rParseFile f fp
  CStreamStd     -> do
    bs <- rReadStdin
    case f "<stdin>" bs of
      Left  err -> do
        liftIO $ putStrLn "error parsing input:"
        liftIO $ putStr err
        liftIO $ Exit.exitWith (Exit.ExitFailure 2)
      Right out -> return out

-- TODO: bad error...
rParseFile :: MonadIO m => (FilePath -> BS.ByteString -> Either String a) -> FilePath -> m a
rParseFile f fp = do
    bs <- rReadFile fp
    case f fp bs of
      Left  err -> do
        liftIO $ putStrLn "error parsing input:"
        liftIO $ putStr err
        liftIO $ Exit.exitWith (Exit.ExitFailure 3)
      Right out -> return out

--------------------------------------------------------------------------------

rWritePakFolder :: MonadIO m => GAP.Pak -> FilePath -> m ()
rWritePakFolder (GAP.Pak _ files) fp =
    let files' = map (\(a, b) -> (Text.unpack a, b)) files
     in liftIO $ rWriteFilesToFolder fp files'

rWriteFilesToFolder :: MonadIO m => FilePath -> [(FilePath, BS.ByteString)] -> m ()
rWriteFilesToFolder folder = mapM_ f
  where
    f (filename, bytes) = do
        let fp = folder <> "/" <> filename
        liftIO $ putStrLn $ "writing file: " <> fp
        liftIO $ BS.writeFile fp bytes

rReadStream :: MonadIO m => CStream -> m BS.ByteString
rReadStream = \case
  CStreamFile fp -> rReadFile fp
  CStreamStd     -> rReadStdin

rReadFile :: MonadIO m => FilePath -> m BS.ByteString
rReadFile = liftIO . BS.readFile

rReadStdin :: MonadIO m => m BS.ByteString
rReadStdin = liftIO BS.getContents

-- | Read stream as lazy bytestring. (Sigh.)
rReadStream' :: MonadIO m => CStream -> m BL.ByteString
rReadStream' = \case
  CStreamFile fp -> rReadFile' fp
  CStreamStd     -> rReadStdin'

-- | Read file as lazy bytestring. (Sigh.)
rReadFile' :: MonadIO m => FilePath -> m BL.ByteString
rReadFile' = liftIO . BL.readFile

-- | Read stdin as lazy bytestring. (Sigh.)
rReadStdin' :: MonadIO m => m BL.ByteString
rReadStdin' = liftIO BL.getContents
