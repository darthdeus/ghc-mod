{-# LANGUAGE DeriveDataTypeable #-}

module Main where

import Config (cProjectVersion)
import Control.Applicative ((<$>))
import Control.Exception (Exception, Handler(..), ErrorCall(..))
import qualified Control.Exception as E
import Data.Typeable (Typeable)
import Data.Version (showVersion)
import Language.Haskell.GhcMod
import Language.Haskell.GhcMod.Monad
import Paths_ghc_mod
import System.Console.GetOpt (OptDescr(..), ArgDescr(..), ArgOrder(..))
import qualified System.Console.GetOpt as O
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStr, hPutStrLn, stdout, stderr, hSetEncoding, utf8)

----------------------------------------------------------------

progVersion :: String
progVersion = "ghc-mod version " ++ showVersion version ++ " compiled by GHC " ++ cProjectVersion ++ "\n"

ghcOptHelp :: String
ghcOptHelp = " [-g GHC_opt1 -g GHC_opt2 ...] "

usage :: String
usage =    progVersion
        ++ "Usage:\n"
        ++ "\t ghc-mod list" ++ ghcOptHelp ++ "[-l] [-d]\n"
        ++ "\t ghc-mod lang [-l]\n"
        ++ "\t ghc-mod flag [-l]\n"
        ++ "\t ghc-mod browse" ++ ghcOptHelp ++ "[-l] [-o] [-d] [-q] [<package>:]<module> [[<package>:]<module> ...]\n"
        ++ "\t ghc-mod check" ++ ghcOptHelp ++ "<HaskellFiles...>\n"
        ++ "\t ghc-mod expand" ++ ghcOptHelp ++ "<HaskellFiles...>\n"
        ++ "\t ghc-mod debug" ++ ghcOptHelp ++ "\n"
        ++ "\t ghc-mod info" ++ ghcOptHelp ++ "<HaskellFile> <module> <expression>\n"
        ++ "\t ghc-mod type" ++ ghcOptHelp ++ "<HaskellFile> <module> <line-no> <column-no>\n"
        ++ "\t ghc-mod find <symbol>\n"
        ++ "\t ghc-mod lint [-h opt] <HaskellFile>\n"
        ++ "\t ghc-mod root\n"
        ++ "\t ghc-mod doc <module>\n"
        ++ "\t ghc-mod boot\n"
        ++ "\t ghc-mod version\n"
        ++ "\t ghc-mod help\n"
        ++ "\n"
        ++ "<module> for \"info\" and \"type\" is not used, anything is OK.\n"
        ++ "It is necessary to maintain backward compatibility.\n"

----------------------------------------------------------------

argspec :: [OptDescr (Options -> Options)]
argspec = [ Option "l" ["tolisp"]
            (NoArg (\opts -> opts { outputStyle = LispStyle }))
            "print as a list of Lisp"
          , Option "h" ["hlintOpt"]
            (ReqArg (\h opts -> opts { hlintOpts = h : hlintOpts opts }) "hlintOpt")
            "hlint options"
          , Option "g" ["ghcOpt"]
            (ReqArg (\g opts -> opts { ghcOpts = g : ghcOpts opts }) "ghcOpt")
            "GHC options"
          , Option "o" ["operators"]
            (NoArg (\opts -> opts { operators = True }))
            "print operators, too"
          , Option "d" ["detailed"]
            (NoArg (\opts -> opts { detailed = True }))
            "print detailed info"
          , Option "q" ["qualified"]
            (NoArg (\opts -> opts { qualified = True }))
            "show qualified names"
          , Option "b" ["boundary"]
            (ReqArg (\s opts -> opts { lineSeparator = LineSeparator s }) "sep")
            "specify line separator (default is Nul string)"
          ]

parseArgs :: [OptDescr (Options -> Options)] -> [String] -> (Options, [String])
parseArgs spec argv
    = case O.getOpt Permute spec argv of
        (o,n,[]  ) -> (foldr id defaultOptions o, n)
        (_,_,errs) -> E.throw (CmdArg errs)

----------------------------------------------------------------

data GHCModError = SafeList
                 | TooManyArguments String
                 | NoSuchCommand String
                 | CmdArg [String]
                 | FileNotExist String deriving (Show, Typeable)

instance Exception GHCModError

----------------------------------------------------------------

evaluateRequest :: [String] -> IO String
evaluateRequest args = do
    let (opt,cmdArg) = parseArgs argspec args
    cradle <- findCradle

    let cmdArg0 = cmdArg !. 0
        cmdArg1 = cmdArg !. 1
        cmdArg3 = cmdArg !. 3
        cmdArg4 = cmdArg !. 4
        remainingArgs = tail cmdArg
        nArgs n f = if length remainingArgs == n
                        then f
                        else E.throw (TooManyArguments cmdArg0)
    case cmdArg0 of
      "list"    -> listModules opt cradle
      "lang"    -> listLanguages opt
      "flag"    -> listFlags opt
      "browse"  -> runGhcMod opt $ concat <$> mapM browse remainingArgs
      "check"   -> runGhcMod opt $ checkSyntax remainingArgs
      "expand"  -> runGhcMod opt $ expandTemplate remainingArgs
      "debug"   -> debugInfo opt cradle
      "info"    -> nArgs 3 infoExpr opt cradle cmdArg1 cmdArg3
      "type"    -> nArgs 4 $ typeExpr opt cradle cmdArg1 (read cmdArg3) (read cmdArg4)
      "find"    -> runGhcMod opt $ nArgs 1 $ findSymbol cmdArg1
      "lint"    -> nArgs 1 withFile (lintSyntax opt) cmdArg1
      "root"    -> rootInfo opt cradle
      "doc"     -> nArgs 1 $ packageDoc opt cradle cmdArg1
      "boot"    -> bootInfo opt
      "version" -> return progVersion
      "help"    -> return $ O.usageInfo usage argspec
      cmd       -> E.throw (NoSuchCommand cmd)

  where
    xs !. idx
      | length xs <= idx = E.throw SafeList
      | otherwise = xs !! idx
    withFile cmd file = do
        exist <- doesFileExist file
        if exist
            then cmd file
            else E.throw (FileNotExist file)

----------------------------------------------------------------

main :: IO ()
main = flip E.catches handlers $ do
-- #if __GLASGOW_HASKELL__ >= 611
    hSetEncoding stdout utf8
-- #endif
    getArgs >>= evaluateRequest >>= putStrLn

  where
    handlers = [Handler (handleThenExit handler1), Handler (handleThenExit handler2)]
    handleThenExit handler e = handler e >> exitFailure

    handler1 :: ErrorCall -> IO ()
    handler1 = print -- for debug

    handler2 :: GHCModError -> IO ()
    handler2 SafeList = printUsage
    handler2 (TooManyArguments cmd) = do
        hPutStrLn stderr $ "\"" ++ cmd ++ "\": Too many arguments"
        printUsage
    handler2 (NoSuchCommand cmd) = do
        hPutStrLn stderr $ "\"" ++ cmd ++ "\" not supported"
        printUsage
    handler2 (CmdArg errs) = do
        mapM_ (hPutStr stderr) errs
        printUsage
    handler2 (FileNotExist file) = do
        hPutStrLn stderr $ "\"" ++ file ++ "\" not found"
        printUsage

    printUsage = hPutStrLn stderr $ '\n' : O.usageInfo usage argspec

