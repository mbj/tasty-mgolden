{- | Golden testing provider for 'tasty'

This module implements the [golden testing pattern](https://ro-che.info/articles/2017-12-04-golden-tests).

-}

module Test.Tasty.MGolden (Mode(..), goldenTest, printDetails) where

import Control.Applicative (empty)
import Prelude hiding (print, putStrLn)
import Data.Foldable (traverse_)
import Data.Proxy (Proxy(..))
import Data.Text (Text)
import Data.Typeable (Typeable)
import Test.Tasty
import Test.Tasty.Options
import Test.Tasty.Providers
import Test.Tasty.Providers.ConsoleFormat

import qualified Data.Algorithm.Diff as Diff
import qualified Data.Text           as Text
import qualified Data.Text.IO        as Text
import qualified System.IO.Error     as Error

-- | Golden test run mode
data Mode
  = RunTest         -- ^ Run the tests, error (with diff) on actual vs expectation mismatch
  | UpdateExpected  -- ^ Run the tests, update the expectation on actual vs expectation mismatch
  deriving stock (Eq, Ord, Typeable, Show)

instance IsOption Mode where
  defaultValue = RunTest
  parseValue = \case
    "test"   -> pure RunTest
    "update" -> pure UpdateExpected
    _other   -> empty

  optionName     = pure "update"
  optionHelp     = pure "Update expected on mismatched example"
  optionCLParser = flagCLParser empty UpdateExpected

data Golden = Golden
  { action       :: IO Text
  , expectedPath :: FilePath
  }
  deriving stock Typeable

instance IsTest Golden where
  run options golden _callback = runGolden golden options
  testOptions = pure . pure $ Option (Proxy :: Proxy Mode)

-- | Define a golden test
goldenTest
  :: String   -- ^ Name of the  test
  -> FilePath -- ^ Path of the expectation file
  -> IO Text  -- ^ Test action
  -> TestTree
goldenTest name expectedPath action = singleTest name Golden{..}

runGolden :: Golden -> OptionSet -> IO Result
runGolden golden@Golden{..} options = do
  actual <- action

  maybe
    (absentFile golden options actual)
    (testExpected golden options actual)
    =<< tryRead expectedPath

absentFile :: Golden -> OptionSet -> Text -> IO Result
absentFile golden@Golden{..} options actual =
  if shouldUpdate options
    then updateExpected golden actual
    else pure $ testFailed "file is absent"

testExpected :: Golden -> OptionSet -> Text -> Text -> IO Result
testExpected golden@Golden{..} options actual expected =
  if expected == actual
    then pure $ testPassed empty
    else mismatch options golden expected actual

mismatch :: OptionSet -> Golden -> Text -> Text -> IO Result
mismatch options golden expected actual =
  if shouldUpdate options
    then updateExpected golden actual
    else pure . testFailedDetails empty $ printDetails Text.putStrLn expected actual

updateExpected :: Golden -> Text -> IO Result
updateExpected Golden{..} actual = do
  Text.writeFile expectedPath actual
  pure $ testPassed "UPDATE"

printDetails :: (Text -> IO ()) -> Text -> Text -> ResultDetailsPrinter
printDetails putStrLn expected actual = ResultDetailsPrinter print
  where
    print :: Int -> (ConsoleFormat -> IO () -> IO ()) -> IO ()
    print _indent formatter
      = traverse_ printDiff
      $ Diff.getGroupedDiff (Text.lines expected) (Text.lines actual)
      where
        printDiff :: Diff.Diff [Text] -> IO ()
        printDiff = \case
          (Diff.Both   line _) -> printLines ' ' neutralFormat line
          (Diff.First  line)   -> printLines '-' removeFormat line
          (Diff.Second line)   -> printLines '+' addFormat line

        printLines :: Char -> ConsoleFormat -> [Text] -> IO ()
        printLines prefix format lines'
          = formatter format
          $ traverse_ printLine lines'
          where
            printLine :: Text -> IO ()
            printLine line = putStrLn $ Text.singleton prefix <> line

addFormat :: ConsoleFormat
addFormat = okFormat

neutralFormat :: ConsoleFormat
neutralFormat = infoOkFormat

removeFormat :: ConsoleFormat
removeFormat = infoFailFormat

shouldUpdate :: OptionSet -> Bool
shouldUpdate options = (lookupOption options :: Mode) == UpdateExpected

tryRead :: FilePath -> IO (Maybe Text)
tryRead path =
  Error.catchIOError
    (pure <$> Text.readFile path)
    handler
  where
    handler :: Error.IOError -> IO (Maybe Text)
    handler error' =
      if Error.isDoesNotExistError error'
        then pure empty
        else Error.ioError error'
