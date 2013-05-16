{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}


-- | A `D.DAWG`-based dictionary with additional information
-- assigned to lexical entries and word forms.


module NLP.HistPL.DAWG
(
-- * Rule
  Rule (..)
, apply
, between

-- * DAWG
, DAWG
-- ** Entry
, Lex (..)
, Key (..)
, Val (..)
, Node
-- ** Entry set
, LexSet
, mkLexSet
, unLexSet
-- , encode
, decode
-- ** Query
, lookup
-- ** Conversion
, fromList
, toList
, entries
, revDAWG
) where


import           Prelude hiding (lookup)
import           Control.Applicative ((<$>), (<*>))
import           Control.Arrow (first)
import           Data.Binary (Binary, get, put)
import           Data.Text.Binary ()
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.DAWG.Static as D


------------------------------------------------------------------------
-- Rule
------------------------------------------------------------------------


-- | A rule for translating a form into another form.
data Rule = Rule {
    -- | Number of characters to cut from the end of the form.
      cut       :: !Int
    -- | A suffix to paste.
    , suffix    :: !T.Text
    } deriving (Show, Eq, Ord)


instance Binary Rule where
    put Rule{..} = put cut >> put suffix
    get = Rule <$> get <*> get


-- | Apply the rule.
apply :: Rule -> T.Text -> T.Text
apply r x = T.take (T.length x - cut r) x `T.append` suffix r


-- | Determine a rule which translates between two strings.
between :: T.Text -> T.Text -> Rule
between source dest =
    let k = lcp source dest
    in  Rule (T.length source - k) (T.drop k dest)
  where
    lcp a b = case T.commonPrefixes a b of
        Just (c, _, _)  -> T.length c
        Nothing         -> 0


------------------------------------------------------------------------
-- Entry componenets (key and value)
------------------------------------------------------------------------


-- | A key of a dictionary entry.
data Key i = Key {
    -- | A path of the entry, i.e. DAWG key.
      path  :: T.Text
    -- | Unique identifier among entries with the same `path`.
    , uid   :: i }
    deriving (Show, Eq, Ord)


-- | A value of the entry.
data Val a w b = Val {
    -- | Additional information assigned to the entry.
      info  :: a
    -- | A map of forms with additional info of type @b@ assigned.
    -- Invariant: in case of a reverse dictionary (from word forms
    -- to base forms) this map should contain exactly one element
    -- (a base form and a corresonding information).
    , forms :: M.Map w b }
    deriving (Show, Eq, Ord)


instance (Ord w, Binary a, Binary w, Binary b) => Binary (Val a w b) where
    put Val{..} = put info >> put forms
    get = Val <$> get <*> get


-- | A dictionary entry consists of a `Key` and a `Val`ue.
data Lex i a b = Lex {
    -- | Entry key.
      lexKey :: Key i
    -- | Entry value.
    , lexVal :: Val a T.Text b }
    deriving (Show, Eq, Ord)


-- | A set of dictionary entries.
type LexSet i a b = M.Map (Key i) (Val a T.Text b)


-- | Make lexical set from a list of entries.
mkLexSet :: Ord i => [Lex i a b] -> LexSet i a b
mkLexSet = M.fromList . map ((,) <$> lexKey <*> lexVal)


-- | List lexical entries.
unLexSet :: LexSet i a b -> [Lex i a b]
unLexSet = map (uncurry Lex) . M.toList


-- | Actual values stored in automaton states contain
-- all entry information but `path`.
type Node i a b = M.Map i (Val a Rule b)


-- | Map function over entry word forms.
mapW :: Ord w' => (w -> w') -> Val a w b -> Val a w' b
mapW f v =
    let g = M.fromList . map (first f) . M.toList
    in  v { forms = g (forms v) }


-- | Decode dictionary value given `path`.
decode :: Ord i => T.Text -> Node i a b -> LexSet i a b
decode x n = M.fromList
    [ (Key x i, mapW (flip apply x) val)
    | (i, val) <- M.toList n ]


-- | Transform entry into a list.
toListE :: Lex i a b -> [(T.Text, i, a, T.Text, b)]
toListE (Lex Key{..} Val{..}) =
    [ (path, uid, info, form, y)
    | (form, y) <- M.assocs forms ]


------------------------------------------------------------------------


-- | A dictionary parametrized over ID @i@, with info @a@ for every
-- (key, i) pair and info @b@ for every (key, i, apply rule key) triple.
type DAWG i a b = D.DAWG Char () (Node i a b)


-- | Lookup the key in the dictionary.
lookup :: Ord i => T.Text -> DAWG i a b -> LexSet i a b
lookup x dict = decode x $ case D.lookup (T.unpack x) dict of
    Just m  -> m
    Nothing -> M.empty


-- | List dictionary lexical entries.
entries :: Ord i => DAWG i a b -> [Lex i a b]
entries = concatMap f . D.assocs where
    f (key, val) = unLexSet $ decode (T.pack key) val


-- | Make dictionary from a list of (key, ID, entry info, form,
-- entry\/form info) tuples.
fromList :: (Ord i, Ord a, Ord b) => [(T.Text, i, a, T.Text, b)] -> DAWG i a b
fromList xs = D.fromListWith union $
    [ ( T.unpack x
      , M.singleton i (Val a (M.singleton (between x y) b)) )
    | (x, i, a, y, b) <- xs ]
  where
    union = M.unionWith $ both const M.union
    both f g (Val x y) (Val x' y') = Val (f x x') (g y y')


-- | Transform dictionary back into the list of (key, ID, key\/ID info, elem,
-- key\/ID\/elem info) tuples.
toList :: (Ord i, Ord a, Ord b) => DAWG i a b -> [(T.Text, i, a, T.Text, b)]
toList = concatMap toListE . entries


-- | Reverse the dictionary.
revDAWG :: (Ord i, Ord a, Ord b) => DAWG i a b -> DAWG i a b
revDAWG = 
    let swap (base, i, x, form, y) = (form, i, x, base, y)
    in  fromList . map swap . toList