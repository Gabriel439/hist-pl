{-# LANGUAGE OverloadedStrings #-} 
{-# LANGUAGE RecordWildCards #-} 
{-# LANGUAGE TupleSections #-} 


{-|
    The module provides functions for working with the binary
    representation of the historical dictionary of Polish.

    It is intended to be imported qualified, to avoid name
    clashes with Prelude functions, e.g. 

    > import qualified NLP.HistPL.Lexicon as H
   
    Use `build` and `loadAll` functions to save/load
    the entire dictionary in/from a given directory.
   
    To search the dictionary, open the binary directory with an
    `open` function.  For example, during a @GHCi@ session:

    >>> hpl <- H.open "srpsdp.bin"
   
    Set the OverloadedStrings extension for convenience:

    >>> :set -XOverloadedStrings
   
    To search the dictionary use the `lookup` function, e.g.

    >>> entries <- H.lookup hpl "dufliwego"

    You can use functions defined in the "NLP.HistPL.Types" module
    to query the entries for a particular feature, e.g.

    >>> map (H.text . H.lemma) entries
    [["dufliwy"]]

    Finally, if you need to follow an ID pointer kept in one entry
    as a reference to another one, use the `load'` or `tryLoad'`
    functions.
-}


module NLP.HistPL.Lexicon
(
-- * Dictionary
  HistPL
, Code (..)
-- ** Key
, Key
, UID
-- ** Open
, tryOpen
, open
-- ** Query
, lookup
, lookupMany
, dictKeys
, tryLoad
, load
, tryLoad'
, load'

-- * Conversion
, build
, loadAll

-- * Modules
-- $modules
, module NLP.HistPL.Types
) where


import Prelude hiding (lookup)
import Control.Applicative ((<$>))
import Control.Monad (unless, guard)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Trans.Maybe (MaybeT (..))
import qualified Control.Monad.LazyIO as LazyIO
import System.IO.Unsafe (unsafeInterleaveIO)
import System.FilePath ((</>))
import System.Directory
    ( createDirectoryIfMissing, createDirectory, doesDirectoryExist )
import Data.List (mapAccumL)
import Data.Binary (Binary, put, get, encodeFile, decodeFile)
import qualified Data.Set as S
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.DAWG.Dynamic as DD

import qualified NLP.HistPL.Binary as B
import           NLP.HistPL.Binary.Util
import qualified NLP.HistPL.DAWG as D
import           NLP.HistPL.Types
import qualified NLP.HistPL.Util as Util


{- $modules
    "NLP.HistPL.Types" module exports hierarchy of data types
    stored in the binary dictionary.
-}


--------------------------------------------------------
-- Subdirectories
--------------------------------------------------------


-- | Path to entries in the binary dictionary.
entryDir :: String
entryDir = "entries"


-- | Path to keys in the binary dictionary.
keyDir :: String
keyDir = "keys"


-- | Path to key map in the binary dictionary.
formFile :: String
formFile = "forms.bin"


--------------------------------------------------------
-- Key
--------------------------------------------------------


-- | A dictionary key which uniquely identifies the lexical entry.
type Key = D.Key UID


-- | A unique identifier among entries with the same `keyForm`.
type UID = Int


-- | The ''main form'' of the lexical entry.
proxy :: LexEntry -> T.Text
proxy entry = case Util.allForms entry of
    (x:_)   -> x
    []      -> error "proxy: entry with no forms"


-- | Convert the key to the path where binary representation of the entry
-- is stored.
showKey :: Key -> String
showKey D.Key{..} = (T.unpack . T.concat) [T.pack (show uid), "-", path]


-- | Parse the key.
parseKey :: String -> Key
parseKey x =
    let (uid'S, (_:form'S)) = break (=='-') x
    in  D.Key (T.pack form'S) (read uid'S)


--------------------------------------------------------
-- Computing keys
--------------------------------------------------------


getKey :: DD.DAWG Char Int -> LexEntry -> (DD.DAWG Char Int, Key)
getKey m x =
    let main = proxy x
        path = T.unpack main
        num  = maybe 0 id (DD.lookup path m) + 1
        key  = D.Key main num
    in  (DD.insert path num m, key)


getKeys :: [LexEntry] -> [Key]
getKeys = snd . mapAccumL getKey DD.empty


--------------------------------------------------------
-- Keys storage
--------------------------------------------------------


-- | Save (key, lexID) pair in the keys component of the binary dictionary.
saveKey :: FilePath -> Key -> T.Text -> IO ()
saveKey path key i = T.writeFile (path </> keyDir </> showKey key) i


-- | Load lexID given the corresponding key.
loadKey :: FilePath -> Key -> IO T.Text
loadKey path key = T.readFile (path </> keyDir </> showKey key)


--------------------------------------------------------
-- Entry storage
--------------------------------------------------------


-- | Save entry in the binary dictionary.
saveEntry :: FilePath -> Key -> LexEntry -> IO ()
saveEntry path key x = do
    saveKey path key (lexID x)
    B.save (path </> entryDir) x


-- -- | Load entry from a disk by its key.
-- loadEntry :: FilePath -> Key -> IO LexEntry
-- loadEntry path key = tryLoadEntry path key >>=
--     maybe (fail "load: failed to load the entry") return


-- | Load entry from a disk by its key.
tryLoadEntry :: FilePath -> Key -> IO (Maybe LexEntry)
tryLoadEntry path key = maybeErr $ do
    B.load (path </> entryDir) =<< loadKey path key


--------------------------------------------------------
-- Binary dictionary
--------------------------------------------------------


-- | A binary dictionary holds additional info of type @a@
-- for every entry and additional info of type @b@ for every
-- word form.
data HistPL = HistPL {
    -- | A path to the binary dictionary.
      dictPath  :: FilePath
    -- | A dictionary with lexicon forms.
    , formMap   :: D.DAWG UID () Code
    }


-- | Code of word form origin.
data Code
    = Orig  -- ^ only from historical dictionary
    | Both  -- ^ from both historical and another dictionary
    | Copy  -- ^ only from another dictionary
    deriving (Show, Eq, Ord)


instance Binary Code where
    put Orig = put '1'
    put Copy = put '2'
    put Both = put '3'
    get = get >>= \x -> return $ case x of
        '1' -> Orig
        '2' -> Copy
        '3' -> Both
        c   -> error $ "get: invalid Code value '" ++ [c] ++ "'"


-- | Open the binary dictionary residing in the given directory.
-- Return Nothing if the directory doesn't exist or if it doesn't
-- constitute a dictionary.
tryOpen :: FilePath -> IO (Maybe HistPL)
tryOpen path = runMaybeT $ do
    formMap'  <- maybeErrT $ decodeFile (path </> formFile)
    doesExist <- liftIO $ doesDirectoryExist (path </> entryDir)
    guard doesExist 
    return $ HistPL path formMap'


-- | Open the binary dictionary residing in the given directory.
-- Raise an error if the directory doesn't exist or if it doesn't
-- constitute a dictionary.
open :: FilePath -> IO HistPL
open path = tryOpen path >>=
    maybe (fail "Failed to open the dictionary") return


-- | List of dictionary keys.
dictKeys :: HistPL -> IO [Key]
dictKeys hpl = map parseKey <$> loadContents (dictPath hpl </> entryDir)


-- | Load lexical entry given its key.  Return `Nothing` if there
-- is no entry with such a key.
tryLoad :: HistPL -> Key -> IO (Maybe LexEntry)
tryLoad hpl key = unsafeInterleaveIO $ tryLoadEntry (dictPath hpl) key


-- | Load lexical entry given its key.  Raise error if there
-- is no entry with such a key.
load :: HistPL -> Key -> IO LexEntry
load hpl key = tryLoad hpl key >>= maybe
    (fail $ "load: failed to open entry with the " ++ show key ++ " key")
    return


-- | Load lexical entry given its ID.  Return `Nothing` if there
-- is no entry with such ID.
tryLoad' :: HistPL -> T.Text -> IO (Maybe LexEntry)
tryLoad' hpl i = unsafeInterleaveIO $ B.tryLoad (dictPath hpl </> entryDir) i


-- | Load lexical entry given its ID.  Raise error if there
-- is no entry with such a key.
load' :: HistPL -> T.Text -> IO LexEntry
load' hpl i = tryLoad' hpl i >>= maybe
    (fail $ "load': failed to load entry with the " ++ T.unpack i ++ " ID")
    return


-- | Lookup the form in the dictionary.
lookup :: HistPL -> T.Text -> IO [(LexEntry, Code)]
lookup hpl x = do
    let lexSet = D.lookup x (formMap hpl)
    sequence
        [ (   , code) <$> load hpl key
        | (key, code) <- getCode =<< M.assocs lexSet ]
  where
    getCode (key, val) =
        [ (key { D.path = base }, code)
        | (base, code) <- M.toList (D.forms val) ]
        

-- | Lookup a set of forms in the dictionary.
lookupMany :: HistPL -> [T.Text] -> IO [(LexEntry, Code)]
lookupMany hpl xs = do
    let keyMap = M.fromListWith min $
            getCode =<< M.assocs =<<
            (flip D.lookup (formMap hpl) <$> xs)
    sequence
        [ (   , code) <$> load hpl key
        | (key, code) <- M.toList keyMap ]
  where
    getCode (key, val) =
        [ (key { D.path = base }, code)
        | (base, code) <- M.toList (D.forms val) ]


--------------------------------------------------------
-- Conversion
--------------------------------------------------------


-- | Construct dictionary from a list of lexical entries and save it in
-- the given directory.  To each entry an additional set of forms can
-- be assigned.  
build :: FilePath -> [(LexEntry, S.Set T.Text)] -> IO (HistPL)
build binPath xs = do
    createDirectoryIfMissing True binPath
    emptyDirectory binPath >>= \empty -> unless empty $ do
        error $ "build: directory " ++ binPath ++ " is not empty"
    createDirectory $ binPath </> entryDir
    createDirectory $ binPath </> keyDir
    formMap' <- D.fromList . concat <$>
        LazyIO.mapM saveBin (zip3 keys entries forms)
    encodeFile (binPath </> formFile) formMap'
    return $ HistPL binPath formMap'
  where
    (entries, forms) = unzip xs
    keys = getKeys entries
    saveBin (key, lexEntry, otherForms) = do
        saveEntry binPath key lexEntry
        let D.Key{..} = key
            histForms = S.fromList (Util.allForms lexEntry)
            onlyHist  = S.difference histForms otherForms
            onlyOther = S.difference otherForms histForms
            both      = S.intersection histForms otherForms
            list c s  = [(y, uid, (), path, c) | y <- S.toList s]
        return $ list Orig onlyHist ++ list Copy onlyOther ++ list Both both


-- | Load all lexical entries in a lazy manner.
loadAll :: HistPL -> IO [(Key, LexEntry)]
loadAll hpl = do
    keys <- dictKeys hpl
    LazyIO.forM keys $ \key -> do
        entry <- load hpl key
        return (key, entry)
