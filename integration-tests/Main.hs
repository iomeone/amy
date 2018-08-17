{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main
  ( main
  ) where

import Control.Exception (throw)
import Control.Monad (unless, when)
import Control.Monad.Except
import Data.Either (isRight)
import Data.Foldable (for_)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text, unpack)
import Data.Traversable (traverse)
import Data.Yaml
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..), exitFailure)
import System.Process

main :: IO ()
main = do
  (testDefs :: [TestDefinition])  <- either throw pure =<< decodeFileEither "tests.yaml"
  results <- traverse runTest testDefs
  unless (and results) exitFailure

runTest :: TestDefinition -> IO Bool
runTest testDef = do
  putStrLn $ "Running test '" ++ unpack (testName testDef) ++ "'..."
  result <- runExceptT $ runTest' testDef
  either (\e -> putStrLn $ "Failed:\n" ++ e) (const $ putStrLn "Success!") result
  pure $ isRight result

runTest' :: TestDefinition -> ExceptT String IO ()
runTest' TestDefinition{..} = do
  let
    sourcePath = testSource </> unpack testName ++ ".amy"
    exePath = testSource </> "a.out"

  -- Ensure source file exists
  exists <- liftIO $ doesFileExist sourcePath
  unless exists $
    throwError $ "File doesn't exist! " ++ sourcePath

  -- Get Prelude
  preludePath <- liftIO $ fromMaybe "stdlib/Prelude.amy" <$> lookupEnv "PRELUDE_LOCATION"

  -- Compile program
  (compilerExitCode, compilerStdout, compilerStderr) <-
    liftIO $ readProcessWithExitCode "amy" ["compile", preludePath, sourcePath] ""
  let compilerExpectedExitCode = if isJust testCompilerStderr then ExitFailure 1 else ExitSuccess
  when (compilerExitCode /= compilerExpectedExitCode) $
    throwError $
      "Incorrect compiler exit code. Expected: " ++ show compilerExpectedExitCode ++
      " got: " ++ show compilerExitCode ++
      (if null compilerStdout then "" else "\nstdout:\n" ++ compilerStdout) ++
      (if null compilerStderr then "" else "\nstderr:\n" ++ compilerStderr)

  for_ testCompilerStderr $ \expected ->
    when (expected /= compilerStderr) $
      throwError $
        "Incorrect compiler stderr.\nExpected:\n" ++ expected ++ "\nGot:\n" ++ compilerStderr

  when (compilerExitCode == ExitSuccess) $ do
    -- Run llvm program
    (programExitCode, programStdout, programStderr) <- liftIO $ readProcessWithExitCode exePath [] ""
    when (programExitCode /= testProgramExitCode) $
      throwError $
        "Incorrect program exit code. Expected: " ++ show testProgramExitCode ++
        " got: " ++ show programExitCode ++
        (if null programStdout then "" else "\nstdout:\n" ++ programStdout) ++
        (if null programStderr then "" else "\nstderr:\n" ++ programStderr)

    for_ testProgramStdout $ \expected ->
      when (expected /= programStdout) $
        throwError $ "Incorrect program stdout.\nExpected:\n" ++ expected ++ "\nGot:\n" ++ programStdout

data TestDefinition
  = TestDefinition
  { testName :: !Text
  , testSource :: !FilePath
  , testCompilerStderr :: !(Maybe String)
  , testProgramExitCode :: !ExitCode
  , testProgramStdout :: !(Maybe String)
  } deriving (Show, Eq)

instance FromJSON TestDefinition where
  parseJSON = withObject "TestDefinition" $ \o -> do
    testName <- o .: "name"
    testSource <- o .: "source"
    testCompilerStderr <- o .:? "compiler_stderr"
    testProgramExitCode <- mkExitCode <$> o .:? "program_exit_code" .!= 0
    testProgramStdout <- o .:? "program_stdout"
    pure TestDefinition{..}

mkExitCode :: Int -> ExitCode
mkExitCode 0 = ExitSuccess
mkExitCode x = ExitFailure x

(</>) :: FilePath -> FilePath -> FilePath
"" </> fp2 = fp2
fp1 </> fp2 =
  if last fp1 == '/'
  then fp1 ++ fp2
  else fp1 ++ "/" ++ fp2
