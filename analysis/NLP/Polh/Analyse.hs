module NLP.Polh.Analyse
( Trie
, LexId
, Token (..)
, Ana (..)
, Other (..)
, buildTrie
, tokenize
, anaSent
, anaWord
, mapL
) where

import Control.Applicative ((<$>))
import Control.Arrow (first)
import qualified Data.Set as S
import qualified Data.Map as M
import qualified Data.Char as C
import qualified Data.Text as T
import qualified Data.PoliMorf as Poli
import qualified NLP.Adict.Trie as Trie

import qualified NLP.Polh.Types as H
import qualified NLP.Polh.Binary as H
import qualified NLP.Polh.Util as H

-- | Lexeme identifier.
type LexId = T.Text

type Trie = Trie.TrieM Char (S.Set LexId)

data Token = Token
    { orth  :: T.Text
    , ana   :: Ana }
    deriving (Show)

-- | Analysis result.
data Ana
    -- | Historical word.
    = Hist [LexId]  -- [H.LexEntry]
    -- | Contemporary word.
    | Cont  -- [M.Interp]
    -- | Unknown word.
    | Unk
    deriving (Show)

data Other
    -- | Punctuation.
    = Pun T.Text
    -- | Space
    | Space T.Text
    deriving (Show)

tokenize :: T.Text -> [Either T.Text Other]
tokenize =
    map mkElem . T.groupBy cmp
  where
    cmp x y
        | C.isPunctuation x = False
        | C.isPunctuation y = False
        | otherwise         = C.isSpace x == C.isSpace y
    mkElem x
        | T.any C.isSpace x         = Right (Space x)
        | T.any C.isPunctuation x   = Right (Pun x)
        | otherwise                 = Left x

anaSent :: Trie -> T.Text -> [Either Token Other]
anaSent trie = mapL (anaWord trie) . tokenize

anaWord :: Trie -> T.Text -> Token
anaWord trie x = Token x $ case Trie.lookup (mkKey x) trie of
    Just xs -> if S.null xs
        then Cont
        else Hist (S.toList xs)
    Nothing -> Unk

-- | Map the function over left elements.
mapL :: (a -> a') -> [Either a b] -> [Either a' b]
mapL f =
    let g (Left x)  = Left (f x)
        g (Right y) = Right y
    in  map g

-- | Parse the LMF historical dictionary, merge it with the PoliMorf
-- and return the resulting trie.
buildTrie
    :: FilePath     -- ^ Path to Polh binary dictionary
    -> FilePath     -- ^ Path to PoliMorf
    -> IO Trie      -- ^ Resulting trie
buildTrie polhPath poliPath = do
    -- TODO: Filter one-word forms?
    baseMap <- Poli.mkBaseMap . filter oneWordEntry
           <$> Poli.readPoliMorf poliPath
    let polh = case H.loadPolh polhPath of
            Nothing -> error "buildTrie: not a polh dictionary"
            Just xs -> mkPolh xs
        polh' = Poli.merge baseMap $ M.fromList polh
        trie = Trie.fromList $ map (first mkKey) (M.assocs polh')
    return $ fmap (fmap rmCode) trie
  where
    mkPolh dict =
        [ (x, S.singleton (H.lexId lx))
        | lx <- dict, x <- H.allForms lx, oneWord x ]
    rmCode (Just (xs, _)) = xs
    rmCode Nothing        = S.empty

-- | Is it a one-word entry?
oneWordEntry :: Entry -> Bool
oneWordEntry = oneWord . Poli.form

-- | Is it a one-word text?
oneWord :: T.Text -> Bool
oneWord = (==1) . length . T.words

-- | Make caseless trie key from the text.
mkKey :: T.Text -> String
mkKey = T.unpack . T.toLower
