{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}

-- | Build the project.

module Stack.Build
  ( build
  , buildLocalTargets
  , loadPackage
  , mkBaseConfigOpts
  , queryBuildInfo
  , splitObjsWarning
  ) where

import           Data.Aeson ( Value (Object, Array), (.=), object )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import           Data.List ( (\\), isPrefixOf )
import           Data.List.Extra ( groupSort )
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Text.Encoding ( decodeUtf8 )
import qualified Data.Text.IO as TIO
import           Data.Text.Read ( decimal )
import qualified Data.Vector as V
import qualified Data.Yaml as Yaml
import qualified Distribution.PackageDescription as C
import           Distribution.Types.Dependency ( Dependency (..), depLibraries )
import           Distribution.Version ( mkVersion )
import           Path ( parent )
import           Stack.Build.ConstructPlan ( constructPlan )
import           Stack.Build.Execute ( executePlan, preFetch, printPlan )
import           Stack.Build.Installed ( getInstalled, toInstallMap )
import           Stack.Build.Source ( localDependencies, projectLocalPackages )
import           Stack.Package ( resolvePackage )
import           Stack.Prelude hiding ( loadPackage )
import           Stack.Setup ( withNewLocalBuildTargets )
import           Stack.Types.Build
                   ( BaseConfigOpts (..), BuildException (..)
                   , BuildPrettyException (..), Plan (..), Task (..)
                   , TaskType (..), taskLocation
                   )
import           Stack.Types.Compiler ( compilerVersionText, getGhcVersion )
import           Stack.Types.Config
                   ( BuildOpts (..), BuildOptsCLI (..), Config (..)
                   , EnvConfig (..), HasBuildConfig, HasConfig (..)
                   , HasEnvConfig (..), HasPlatform (..), HasSourceMap
                   , actualCompilerVersionL, buildOptsL, cabalVersionL
                   , installationRootDeps, installationRootLocal
                   , packageDatabaseDeps, packageDatabaseExtra
                   , packageDatabaseLocal, stackYamlL, wantedCompilerVersionL
                   )
import           Stack.Types.NamedComponent ( exeComponents )
import           Stack.Types.Package
                   ( InstallLocation (..), LocalPackage (..), Package (..)
                   , PackageConfig (..), lpFiles, lpFilesForComponents )
import           Stack.Types.SourceMap
                   ( CommonPackage (..), ProjectPackage (..), SMTargets (..)
                   , SourceMap (..), Target (..) )
import           System.Terminal ( fixCodePage )

newtype CabalVersionPrettyException
  = CabalVersionNotSupported Version
  deriving (Show, Typeable)

instance Pretty CabalVersionPrettyException where
  pretty (CabalVersionNotSupported cabalVer) =
    "[S-5973]"
    <> line
    <> fillSep
         [ flow "Stack does not support Cabal versions before 1.22, but \
                \version"
         , fromString $ versionString cabalVer
         , flow "was found. To fix this, consider updating the snapshot to"
         , style Shell "lts-3.0"
         , flow "or later or to"
         , style Shell "nightly-2015-05-05"
         , flow "or later."
         ]

instance Exception CabalVersionPrettyException

data QueryException
  = SelectorNotFound [Text]
  | IndexOutOfRange [Text]
  | NoNumericSelector [Text]
  | CannotApplySelector Value [Text]
  deriving (Show, Typeable)

instance Exception QueryException where
  displayException (SelectorNotFound sels) =
    err "[S-4419]" "Selector not found" sels
  displayException (IndexOutOfRange sels) =
    err "[S-8422]" "Index out of range" sels
  displayException (NoNumericSelector sels) =
    err "[S-4360]" "Encountered array and needed numeric selector" sels
  displayException (CannotApplySelector value sels) =
    err "[S-1711]" ("Cannot apply selector to " ++ show value) sels

-- | Helper function for 'QueryException' instance of 'Show'
err :: String -> String -> [Text] -> String
err msg code sels = "Error: " ++ code ++ "\n" ++ msg ++ ": " ++ show sels

-- | Build.
--
--   If a buildLock is passed there is an important contract here.  That lock must
--   protect the snapshot, and it must be safe to unlock it if there are no further
--   modifications to the snapshot to be performed by this build.
build :: HasEnvConfig env
      => Maybe (Set (Path Abs File) -> IO ()) -- ^ callback after discovering all local files
      -> RIO env ()
build msetLocalFiles = do
  mcp <- view $ configL.to configModifyCodePage
  ghcVersion <- view $ actualCompilerVersionL.to getGhcVersion
  fixCodePage mcp ghcVersion $ do
    bopts <- view buildOptsL
    sourceMap <- view $ envConfigL.to envConfigSourceMap
    locals <- projectLocalPackages
    depsLocals <- localDependencies
    let allLocals = locals <> depsLocals

    checkSubLibraryDependencies (Map.elems $ smProject sourceMap)

    boptsCli <- view $ envConfigL.to envConfigBuildOptsCLI
    -- Set local files, necessary for file watching
    stackYaml <- view stackYamlL
    for_ msetLocalFiles $ \setLocalFiles -> do
      files <-
        if boptsCLIWatchAll boptsCli
        then sequence [lpFiles lp | lp <- allLocals]
        else forM allLocals $ \lp -> do
          let pn = packageName (lpPackage lp)
          case Map.lookup pn (smtTargets $ smTargets sourceMap) of
            Nothing ->
              pure Set.empty
            Just (TargetAll _) ->
              lpFiles lp
            Just (TargetComps components) ->
              lpFilesForComponents components lp
      liftIO $ setLocalFiles $ Set.insert stackYaml $ Set.unions files

    checkComponentsBuildable allLocals

    installMap <- toInstallMap sourceMap
    (installedMap, globalDumpPkgs, snapshotDumpPkgs, localDumpPkgs) <-
        getInstalled installMap

    baseConfigOpts <- mkBaseConfigOpts boptsCli
    plan <- constructPlan baseConfigOpts localDumpPkgs loadPackage sourceMap installedMap (boptsCLIInitialBuildSteps boptsCli)

    allowLocals <- view $ configL.to configAllowLocals
    unless allowLocals $ case justLocals plan of
      [] -> pure ()
      localsIdents -> throwM $ LocalPackagesPresent localsIdents

    checkCabalVersion
    warnAboutSplitObjs bopts
    warnIfExecutablesWithSameNameCouldBeOverwritten locals plan

    when (boptsPreFetch bopts) $
        preFetch plan

    if boptsCLIDryrun boptsCli
      then printPlan plan
      else executePlan
             boptsCli
             baseConfigOpts
             locals
             globalDumpPkgs
             snapshotDumpPkgs
             localDumpPkgs
             installedMap
             (smtTargets $ smTargets sourceMap)
             plan

buildLocalTargets ::
     HasEnvConfig env
  => NonEmpty Text
  -> RIO env (Either SomeException ())
buildLocalTargets targets =
  tryAny $ withNewLocalBuildTargets (NE.toList targets) $ build Nothing

justLocals :: Plan -> [PackageIdentifier]
justLocals =
  map taskProvides .
  filter ((== Local) . taskLocation) .
  Map.elems .
  planTasks

checkCabalVersion :: HasEnvConfig env => RIO env ()
checkCabalVersion = do
  cabalVer <- view cabalVersionL
  when (cabalVer < mkVersion [1, 22]) $
    prettyThrowM $ CabalVersionNotSupported cabalVer

-- | See https://github.com/commercialhaskell/stack/issues/1198.
warnIfExecutablesWithSameNameCouldBeOverwritten ::
     HasTerm env
  => [LocalPackage]
  -> Plan
  -> RIO env ()
warnIfExecutablesWithSameNameCouldBeOverwritten locals plan = do
  logDebug "Checking if we are going to build multiple executables with the same name"
  forM_ (Map.toList warnings) $ \(exe, (toBuild, otherLocals)) -> do
    let exe_s
          | length toBuild > 1 = flow "several executables with the same name:"
          | otherwise = "executable"
        exesText pkgs =
          fillSep $ punctuate
            ","
            [ style
                PkgComponent
                (fromString $ packageNameString p <> ":" <> T.unpack exe)
            | p <- pkgs
            ]
    prettyWarnL $
         [ "Building"
         , exe_s
         , exesText toBuild <> "."
         ]
      <> [ fillSep
             [ flow "Only one of them will be available via"
             , style Shell "stack exec"
             , flow "or locally installed."
             ]
         | length toBuild > 1
         ]
      <> [ fillSep
             [ flow "Other executables with the same name might be overwritten:"
             , exesText otherLocals <> "."
             ]
         | not (null otherLocals)
         ]
 where
  -- Cases of several local packages having executables with the same name.
  -- The Map entries have the following form:
  --
  --  executable name: ( package names for executables that are being built
  --                   , package names for other local packages that have an
  --                     executable with the same name
  --                   )
  warnings :: Map Text ([PackageName],[PackageName])
  warnings =
    Map.mapMaybe
      (\(pkgsToBuild,localPkgs) ->
        case (pkgsToBuild,NE.toList localPkgs \\ NE.toList pkgsToBuild) of
          (_ :| [],[]) ->
            -- We want to build the executable of single local package
            -- and there are no other local packages with an executable of
            -- the same name. Nothing to warn about, ignore.
            Nothing
          (_,otherLocals) ->
            -- We could be here for two reasons (or their combination):
            -- 1) We are building two or more executables with the same
            --    name that will end up overwriting each other.
            -- 2) In addition to the executable(s) that we want to build
            --    there are other local packages with an executable of the
            --    same name that might get overwritten.
            -- Both cases warrant a warning.
            Just (NE.toList pkgsToBuild,otherLocals))
      (Map.intersectionWith (,) exesToBuild localExes)
  exesToBuild :: Map Text (NonEmpty PackageName)
  exesToBuild =
    collect
      [ (exe,pkgName')
      | (pkgName',task) <- Map.toList (planTasks plan)
      , TTLocalMutable lp <- [taskType task]
      , exe <- (Set.toList . exeComponents . lpComponents) lp
      ]
  localExes :: Map Text (NonEmpty PackageName)
  localExes =
    collect
      [ (exe,packageName pkg)
      | pkg <- map lpPackage locals
      , exe <- Set.toList (packageExes pkg)
      ]
  collect :: Ord k => [(k,v)] -> Map k (NonEmpty v)
  collect = Map.map NE.fromList . Map.fromDistinctAscList . groupSort

warnAboutSplitObjs :: HasTerm env => BuildOpts -> RIO env ()
warnAboutSplitObjs bopts | boptsSplitObjs bopts =
  prettyWarnL
    [ flow "Building with"
    , style Shell "--split-objs"
    , flow "is enabled."
    , flow splitObjsWarning
    ]
warnAboutSplitObjs _ = pure ()

splitObjsWarning :: String
splitObjsWarning =
  "Note that this feature is EXPERIMENTAL, and its behavior may be changed and \
  \improved. You will need to clean your workdirs before use. If you want to \
  \compile all dependencies with split-objs, you will need to delete the \
  \snapshot (and all snapshots that could reference that snapshot)."

-- | Get the @BaseConfigOpts@ necessary for constructing configure options
mkBaseConfigOpts :: (HasEnvConfig env)
                 => BuildOptsCLI -> RIO env BaseConfigOpts
mkBaseConfigOpts boptsCli = do
  bopts <- view buildOptsL
  snapDBPath <- packageDatabaseDeps
  localDBPath <- packageDatabaseLocal
  snapInstallRoot <- installationRootDeps
  localInstallRoot <- installationRootLocal
  packageExtraDBs <- packageDatabaseExtra
  pure BaseConfigOpts
    { bcoSnapDB = snapDBPath
    , bcoLocalDB = localDBPath
    , bcoSnapInstallRoot = snapInstallRoot
    , bcoLocalInstallRoot = localInstallRoot
    , bcoBuildOpts = bopts
    , bcoBuildOptsCLI = boptsCli
    , bcoExtraDBs = packageExtraDBs
    }

-- | Provide a function for loading package information from the package index
loadPackage ::
     (HasBuildConfig env, HasSourceMap env)
  => PackageLocationImmutable
  -> Map FlagName Bool
  -> [Text] -- ^ GHC options
  -> [Text] -- ^ Cabal configure options
  -> RIO env Package
loadPackage loc flags ghcOptions cabalConfigOpts = do
  compiler <- view actualCompilerVersionL
  platform <- view platformL
  let pkgConfig = PackageConfig
        { packageConfigEnableTests = False
        , packageConfigEnableBenchmarks = False
        , packageConfigFlags = flags
        , packageConfigGhcOptions = ghcOptions
        , packageConfigCabalConfigOpts = cabalConfigOpts
        , packageConfigCompilerVersion = compiler
        , packageConfigPlatform = platform
        }
  resolvePackage pkgConfig <$> loadCabalFileImmutable loc

-- | Query information about the build and print the result to stdout in YAML format.
queryBuildInfo :: HasEnvConfig env
               => [Text] -- ^ selectors
               -> RIO env ()
queryBuildInfo selectors0 =
      rawBuildInfo
  >>= select id selectors0
  >>= liftIO . TIO.putStrLn . addGlobalHintsComment . decodeUtf8 . Yaml.encode
 where
  select _ [] value = pure value
  select front (sel:sels) value =
    case value of
      Object o ->
        case KeyMap.lookup (Key.fromText sel) o of
          Nothing -> throwIO $ SelectorNotFound sels'
          Just value' -> cont value'
      Array v ->
        case decimal sel of
          Right (i, "")
            | i >= 0 && i < V.length v -> cont $ v V.! i
            | otherwise -> throwIO $ IndexOutOfRange sels'
          _ -> throwIO $ NoNumericSelector sels'
      _ -> throwIO $ CannotApplySelector value sels'
   where
    cont = select (front . (sel:)) sels
    sels' = front [sel]
  -- Include comments to indicate that this portion of the "stack
  -- query" API is not necessarily stable.
  addGlobalHintsComment
    | null selectors0 = T.replace globalHintsLine ("\n" <> globalHintsComment <> globalHintsLine)
    -- Append comment instead of pre-pending. The reasoning here is
    -- that something *could* expect that the result of 'stack query
    -- global-hints ghc-boot' is just a string literal. Seems easier
    -- for to expect the first line of the output to be the literal.
    | ["global-hints"] `isPrefixOf` selectors0 = (<> ("\n" <> globalHintsComment))
    | otherwise = id
  globalHintsLine = "\nglobal-hints:\n"
  globalHintsComment = T.concat
    [ "# Note: global-hints is experimental and may be renamed / removed in the future.\n"
    , "# See https://github.com/commercialhaskell/stack/issues/3796"
    ]
-- | Get the raw build information object
rawBuildInfo :: HasEnvConfig env => RIO env Value
rawBuildInfo = do
  locals <- projectLocalPackages
  wantedCompiler <- view $ wantedCompilerVersionL.to (utf8BuilderToText . display)
  actualCompiler <- view $ actualCompilerVersionL.to compilerVersionText
  pure $ object
    [ "locals" .= Object (KeyMap.fromList $ map localToPair locals)
    , "compiler" .= object
        [ "wanted" .= wantedCompiler
        , "actual" .= actualCompiler
        ]
    ]
 where
  localToPair lp =
    (Key.fromText $ T.pack $ packageNameString $ packageName p, value)
   where
    p = lpPackage lp
    value = object
      [ "version" .= CabalString (packageVersion p)
      , "path" .= toFilePath (parent $ lpCabalFile lp)
      ]

checkComponentsBuildable :: MonadThrow m => [LocalPackage] -> m ()
checkComponentsBuildable lps =
  unless (null unbuildable) $
    prettyThrowM $ SomeTargetsNotBuildable unbuildable
 where
  unbuildable =
    [ (packageName (lpPackage lp), c)
    | lp <- lps
    , c <- Set.toList (lpUnbuildable lp)
    ]

-- | Find if any sublibrary dependency (other than internal libraries) exists in
-- each project package.
checkSubLibraryDependencies :: HasTerm env => [ProjectPackage] -> RIO env ()
checkSubLibraryDependencies projectPackages =
  forM_ projectPackages $ \projectPackage -> do
    C.GenericPackageDescription pkgDesc _ _ lib subLibs foreignLibs exes tests benches <-
      liftIO $ cpGPD . ppCommon $ projectPackage

    let pName = pkgName . C.package $ pkgDesc
        dependencies = concatMap getDeps subLibs <>
                       concatMap getDeps foreignLibs <>
                       concatMap getDeps exes <>
                       concatMap getDeps tests <>
                       concatMap getDeps benches <>
                       maybe [] C.condTreeConstraints lib
        notInternal (Dependency pName' _ _) = pName' /= pName
        publicDependencies = filter notInternal dependencies
        publicLibraries = concatMap (toList . depLibraries) publicDependencies

    when (subLibDepExist publicLibraries) $
      prettyWarnS
        "Sublibrary dependency is not supported, this will almost certainly \
        \fail."
 where
  getDeps (_, C.CondNode _ dep _) = dep
  subLibDepExist = any
    ( \case
        C.LSubLibName _ -> True
        C.LMainLibName  -> False
    )
