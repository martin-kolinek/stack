{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Stack.Options.Completion
    ( ghcOptsCompleter
    , targetCompleter
    , flagCompleter
    , projectExeCompleter
    ) where

import           Control.Monad.Logger (LogLevel (LevelOther))
import           Data.Char (isSpace)
import           Data.List (isPrefixOf)
import           Data.List.Extra (nubOrd)
import qualified Data.Map as Map
import           Data.Maybe
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Distribution.PackageDescription as C
import           Options.Applicative
import           Options.Applicative.Builder.Extra
import           Stack.Config (getLocalPackages)
import           Stack.Options.GlobalParser (globalOptsFromMonoid)
import           Stack.Runners (loadConfigWithOpts)
import           Stack.Setup
import           Stack.Types.Config
import           Stack.Types.FlagName
import           Stack.Types.Package
import           Stack.Types.PackageName
import           Stack.Types.StackT
import           System.Process (readProcess)
import           Language.Haskell.TH.Syntax (runIO, lift)

ghcOptsCompleter :: Completer
ghcOptsCompleter = mkCompleter $ \inputRaw -> return $
    let input = unescapeBashArg inputRaw
        (curArgReversed, otherArgsReversed) = break isSpace (reverse input)
        curArg = reverse curArgReversed
        otherArgs = reverse otherArgsReversed
     in if null curArg then [] else
         map (otherArgs ++) $
         filter (curArg `isPrefixOf`)
                -- Technically, we should be consulting the user's current ghc,
                -- but that would require loading up a BuildConfig.
                $(runIO (readProcess "ghc" ["--show-options"] "") >>= lift . lines)

-- TODO: Ideally this would pay attention to --stack-yaml, may require
-- changes to optparse-applicative.

buildConfigCompleter
    :: (String -> StackT EnvConfig IO [String])
    -> Completer
buildConfigCompleter inner = mkCompleter $ \inputRaw -> do
    let input = unescapeBashArg inputRaw
    case input of
        -- If it looks like a flag, skip this more costly completion.
        ('-': _) -> return []
        _ -> do
            let go = (globalOptsFromMonoid False mempty)
                    { globalLogLevel = LevelOther "silent" }
            lc <- loadConfigWithOpts go
            bconfig <- runStackTGlobal () go $
                lcLoadBuildConfig lc (globalCompiler go)
            envConfig <-
                runStackTGlobal bconfig go (setupEnv Nothing)
            runStackTGlobal envConfig go (inner input)

targetCompleter :: Completer
targetCompleter = buildConfigCompleter $ \input -> do
    lpvs <- fmap lpProject getLocalPackages
    return $
        filter (input `isPrefixOf`) $
        concatMap allComponentNames (Map.toList lpvs)
  where
    allComponentNames (name, lpv) =
        map (T.unpack . renderPkgComponent . (name,)) (Set.toList (lpvComponents lpv))

flagCompleter :: Completer
flagCompleter = buildConfigCompleter $ \input -> do
    lpvs <- fmap lpProject getLocalPackages
    bconfig <- view buildConfigL
    let wildcardFlags
            = nubOrd
            $ concatMap (\(name, lpv) ->
                map (\fl -> "*:" ++ flagString name fl) (C.genPackageFlags (lpvGPD lpv)))
            $ Map.toList lpvs
        normalFlags
            = concatMap (\(name, lpv) ->
                map (\fl -> packageNameString name ++ ":" ++ flagString name fl)
                    (C.genPackageFlags (lpvGPD lpv)))
            $ Map.toList lpvs
        flagString name fl =
            case C.flagName fl of
                C.FlagName flname -> (if flagEnabled name fl then "-" else "") ++ flname
        flagEnabled name fl =
            fromMaybe (C.flagDefault fl) $
            Map.lookup (fromCabalFlagName (C.flagName fl)) $
            Map.findWithDefault Map.empty name (bcFlags bconfig)
    return $ filter (input `isPrefixOf`) $
        case input of
            ('*' : ':' : _) -> wildcardFlags
            ('*' : _) -> wildcardFlags
            _ -> normalFlags

projectExeCompleter :: Completer
projectExeCompleter = buildConfigCompleter $ \input -> do
    lpvs <- fmap lpProject getLocalPackages
    return $
        filter (input `isPrefixOf`) $
        nubOrd $
        concatMap (\(_, lpv) -> map fst (C.condExecutables (lpvGPD lpv))) $
        Map.toList lpvs
