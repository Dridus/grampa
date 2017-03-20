{-# Language FlexibleContexts, FlexibleInstances, RankNTypes, RecordWildCards, ScopedTypeVariables, 
             StandaloneDeriving, TemplateHaskell, UndecidableInstances #-}
module Main where

import Control.Applicative (Applicative, Alternative, pure, empty, many, optional, (<*>), (*>), (<|>))
import Control.Monad (MonadPlus(mzero, mplus), guard, liftM, liftM2, void)
import Data.Char (isSpace, isLetter)
import Data.List (find, minimumBy, nub, sort)
import Data.Monoid (Monoid(..), Product(..), (<>))
import Data.Monoid.Cancellative (LeftReductiveMonoid(..))
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid(factors))
import Data.Monoid.Textual (TextualMonoid(toString))
import Data.Typeable (Typeable)
import Data.Word (Word8, Word64)
import Text.Parser.Combinators (sepBy1, skipMany)

import Test.Feat (Enumerable(..), Enumerate, FreePair(Free), consts, shared, unary, uniform)
import Test.Feat.Enumerate (pay)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.QuickCheck (Arbitrary(..), Gen, Positive(..), Property,
                              (===), (==>), (.&&.), forAll, property, sized, testProperty, within)
import Test.QuickCheck.Checkers (Binop, EqProp(..), TestBatch, unbatch)
import Test.QuickCheck.Classes (functor, monad, monoid, applicative, alternative,
                                monadFunctor, monadApplicative, monadOr, monadPlus)

import qualified Rank2
import qualified Rank2.TH
import Text.Grampa

import qualified Test.Examples

import Prelude hiding (null, takeWhile)

data Recursive f = Recursive{start :: f String,
                             rec :: f [String],
                             one :: f String,
                             next :: f String}
deriving instance (Show (f String), Show (f [String])) => Show (Recursive f)

$(Rank2.TH.deriveAll ''Recursive)

recursiveManyGrammar Recursive{..} = Recursive{
   start= optional (string "[") *> (concat <$> rec) <* optional next,
   rec= (:) <$> one <*> rec <|> pure [],
   one = string "(" *> start <* string ")",
   next= string "]"}

nameListGrammar = fixGrammarAnalysis nameListGrammarBuilder
nameListGrammarBuilder g@Recursive{..} = Recursive{
   start= pure (const . unwords) <*> rec <*> (True <$ symbol "," <* symbol "..." <|> pure False) <|>
          pure id <*> symbol "..." <?> "start",
   rec= pure id <*> (sepBy1 one (ignorable *> string "," <* whiteSpace <?> "comma") <?> "rec sepBy1") <?> "rec",
   one= do ignorable
           identifier <- ((:) <$> satisfyChar isLetter <*> (toString (const "") <$> takeCharsWhile isLetter))
           guard (identifier /= "reserved")
           pure id <*> pure identifier
        <?> "one",
   next= string "--" *> (toString (const "") <$> takeCharsWhile (/= '\n') <* (void (char '\n') <|> endOfInput)) <?> "next"
   }

symbol s = ignorable *> string s <* ignorable
-- ignorable g = whiteSpace *> skipMany (next g *> whiteSpace <?> "ignorable1") <?> "ignorable"
ignorable = whiteSpace *> (leftRecursive False (next nameListGrammar) *> ignorable <<|> pure ())

main = defaultMain tests

tests = testGroup "Grampa" [
           let g = fixGrammarAnalysis recursiveManyGrammar
           in testGroup "recursive"
              [testProperty "minimal" $ parseAll g start "()" == Right [""],
               testProperty "bracketed" $ parseAll g start "[()]" == Right [""],
               testProperty "name list" $ parseAll nameListGrammar start "foo, bar" == Right ["foo bar"]],
           testGroup "arithmetic"
             [testProperty "arithmetic"   $ Test.Examples.parseArithmetical,
              testProperty "comparisons"  $ Test.Examples.parseComparison,
              testProperty "boolean"      $ Test.Examples.parseBoolean,
              testProperty "conditionals" $ Test.Examples.parseConditional],
           testGroup "primitives"
             [testProperty "anyToken mempty" $ results (simpleParse anyToken "") == [],
              testProperty "anyToken list" $ \(x::Word8) xs-> simpleParse anyToken (x:xs) == Right [([x],xs)],
              testProperty "token success" $ \(x::Word8) xs-> simpleParse (token [x]) (x:xs) == Right [([x],xs)],
              testProperty "token failure" $ \(x::Word8) y xs->
                   x /= y ==> results (simpleParse (token [y]) (x:xs)) == [],
              testProperty "token mempty" $ \x-> results (simpleParse (token [x]) "") == [],
              testProperty "satisfy success" $ \bools->
                   simpleParse (satisfy head) (True:bools) == Right [([True], bools)],
              testProperty "satisfy failure" $ \bools-> results (simpleParse (satisfy head) (False:bools)) == [],
              testProperty "satisfy mempty" $ results (simpleParse (satisfy (undefined :: [Char] -> Bool)) []) == [],
              testProperty "string success" $ \(xs::[Word8]) ys->
                   simpleParse (string xs) (xs <> ys) == Right [(xs, ys)],
              testProperty "string" $ \(xs::[Word8]) ys->
                   not (xs `isPrefixOf` ys) ==> results (simpleParse (string xs) ys) == [],
              testProperty "endOfInput mempty" $ simpleParse endOfInput "" == Right [((),"")],
              testProperty "endOfInput failure" $ \s-> s /= "" ==> results (simpleParse endOfInput s) == []],
           testGroup "lookAhead"
             [testProperty "lookAhead" lookAheadP,
              testProperty "lookAhead p *> p" lookAheadConsumeP,
              testProperty "lookAhead or not" lookAheadOrNotP,
              testProperty "notFollowedBy p *> p" lookAheadNotAndP,
              testProperty "not not" lookAheadNotNotP,
              testProperty "lookAhead anyToken" lookAheadTokenP],
           testGroup "classes"
             [testBatch (monoid parser3s),
              testBatch (functor parser3s),
              testBatch (applicative parser3s),
              testBatch (alternative parser2s),
              testBatch $ monad parser3s,
              testBatch $ monadFunctor parser2s,
              testBatch $ monadApplicative parser2s,
              -- testBatch $ monadOr parser2s,
              testBatch $ monadPlus parser2s
             ]]
   where lookAheadP :: String -> DescribedParser String [Bool] -> Bool
         lookAheadConsumeP :: DescribedParser String [Bool] -> Property
         lookAheadOrNotP :: DescribedParser String () -> Property
         lookAheadNotAndP :: DescribedParser String [Bool] -> Property
         lookAheadNotNotP :: DescribedParser String [Bool] -> Property
         lookAheadTokenP :: Char -> String -> Bool
         
         lookAheadP xs (DescribedParser _ p) =
            simpleParse (lookAhead p) xs == (map (const xs <$>) <$> (simpleParse p xs))
         lookAheadConsumeP (DescribedParser _ p) = (lookAhead p *> p :: Parser (Rank2.Singleton [Bool]) String [Bool])
                                                   =-= p
         lookAheadOrNotP (DescribedParser _ p) = within 2000000 $
            (notFollowedBy p <|> lookAhead p) =-= (mempty :: Parser (Rank2.Singleton ()) String ())
         lookAheadNotAndP (DescribedParser _ p) = within 2000000 $
            (notFollowedBy p *> p) =-= (empty :: Parser (Rank2.Singleton [Bool]) String [Bool])
         lookAheadNotNotP (DescribedParser d p) =
            notFollowedBy (notFollowedBy p) =-= (void (lookAhead p) :: Parser (Rank2.Singleton ()) String ())
         lookAheadTokenP x xs = simpleParse (lookAhead anyToken) (x:xs) == Right [([x], x:xs)]

instance Enumerable (DescribedParser s r) => Arbitrary (DescribedParser s r) where
   arbitrary = sized uniform

testBatch :: TestBatch -> TestTree
testBatch (label, tests) = testGroup label (uncurry testProperty . (within 1000000 <$>) <$> tests)

parser2s :: DescribedParser ([Bool], [Bool]) ([Bool], [Bool])
parser2s = undefined

parser3s :: DescribedParser ([Bool], [Bool], [Bool]) ([Bool], [Bool], [Bool])
parser3s = undefined

data DescribedParser s r = DescribedParser String (forall g. (Typeable g, Rank2.Functor g) => Parser g s r)

instance Show (DescribedParser s r) where
   show (DescribedParser d _) = d

instance (Show s, MonoidNull s, Monoid r) => Monoid (DescribedParser s r) where
   mempty = DescribedParser "mempty" mempty
   DescribedParser d1 p1 `mappend` DescribedParser d2 p2 = DescribedParser (d1 ++ " <> " ++ d2) (mappend p1 p2)

instance (Ord r, Show r, EqProp r, Eq s, EqProp s, Show s, FactorialMonoid s, Arbitrary s) =>
         EqProp (Parser (Rank2.Singleton r) s r) where
   p1 =-= p2 = forAll arbitrary (\s-> nub (results $ simpleParse p1 s) =-= nub (results $ simpleParse p2 s))

instance (FactorialMonoid s, Show s, EqProp s, Arbitrary s, Ord r, Show r, EqProp r, Typeable r) =>
         EqProp (DescribedParser s r) where
   DescribedParser _ p1 =-= DescribedParser _ p2 = forAll arbitrary $ \s->
      results (simpleParse p1 s) =-= results (simpleParse p2 s)

instance Monoid s => Functor (DescribedParser s) where
   fmap f (DescribedParser d p) = DescribedParser ("fmap ? " ++ d) (fmap f p)

instance (Show s, Monoid s) => Applicative (DescribedParser s) where
   pure x = DescribedParser "pure ?" (pure x)
   DescribedParser d1 p1 <*> DescribedParser d2 p2 = DescribedParser (d1 ++ " <*> " ++ d2) (p1 <*> p2)

instance (Show s, Monoid s) => Monad (DescribedParser s) where
   return x = DescribedParser "return ?" (return x)
   DescribedParser d1 p1 >>= f = DescribedParser (d1 ++ " >>= ?") (p1 >>= \x-> let DescribedParser _ p = f x in p)
   DescribedParser d1 p1 >> DescribedParser d2 p2 = DescribedParser (d1 ++ " >> " ++ d2) (p1 >> p2)

instance (Show s, Monoid s) => Alternative (DescribedParser s) where
   empty = DescribedParser "empty" empty
   DescribedParser d1 p1 <|> DescribedParser d2 p2 = DescribedParser (d1 ++ " <|> " ++ d2) (p1 <|> p2)

instance (Show s, Monoid s) => MonadPlus (DescribedParser s) where
   mzero = DescribedParser "mzero" mzero
   DescribedParser d1 p1 `mplus` DescribedParser d2 p2 = DescribedParser (d1 ++ " `mplus` " ++ d2) (mplus p1 p2)

instance forall s. (FactorialMonoid s, LeftReductiveMonoid s, Ord s, Typeable s, Show s, Enumerable s) =>
         Enumerable (DescribedParser s s) where
   enumerate = consts (pure <$> [DescribedParser "anyToken" anyToken,
                                 DescribedParser "getInput" getInput,
                                 DescribedParser "empty" empty,
                                 DescribedParser "mempty" mempty])
               <> pay (unary $ \t-> DescribedParser "token" (token t))
               <> pay (unary $ \s-> DescribedParser "string" (string s))
               <> pay (unary $ \pred-> DescribedParser "satisfy" (satisfy pred))
               <> pay (unary $ \pred-> DescribedParser "takeWhile" (takeWhile pred))
               <> pay (unary $ \pred-> DescribedParser "takeWhile1" (takeWhile1 pred))
               <> binary " *> " (*>)
               <> binary " <> " (<>)
               <> binary " <|> " (<|>)
      where binary :: String -> (forall g. Rank2.Functor g => Parser g s s -> Parser g s s -> Parser g s s)
                   -> Enumerate (DescribedParser s s)
            binary nm op = (\(Free (DescribedParser d1 p1, DescribedParser d2 p2))-> DescribedParser (d1 <> nm <> d2) (op p1 p2))
                           <$> pay enumerate

instance forall s r. (Ord s, FactorialMonoid s, LeftReductiveMonoid s, Show s, Enumerable s) =>
         Enumerable (DescribedParser s ()) where
   enumerate = consts (pure <$> [DescribedParser "endOfInput" endOfInput])
               <> pay (unary $ \(DescribedParser d p :: DescribedParser s s)-> DescribedParser ("void " <> d) (void p))
               <> pay (unary $ \(DescribedParser d p :: DescribedParser s s)->
                                  DescribedParser ("(notFollowedBy " <> d <> ")") (notFollowedBy p))

instance forall s r. (Show s, FactorialMonoid s, Typeable s) => Enumerable (DescribedParser s [Bool]) where
   enumerate = consts (pure <$> [DescribedParser "empty" empty,
                                 DescribedParser "mempty" mempty])
               <> pay (unary $ \r-> DescribedParser ("(pure " ++ shows r ")") (pure r))
               <> pay (unary $ \(DescribedParser d p)-> DescribedParser ("(lookAhead " <> d <> ")") (lookAhead p))
               <> binary " *> " (*>)
               <> binary " <> " (<>)
               <> binary " <|> " (<|>)
      where binary :: String
                   -> (forall g. Rank2.Functor g => Parser g s [Bool] -> Parser g s [Bool] -> Parser g s [Bool])
                   -> Enumerate (DescribedParser s [Bool])
            binary nm op = (\(Free (DescribedParser d1 p1, DescribedParser d2 p2))-> DescribedParser (d1 <> nm <> d2) (op p1 p2))
                           <$> pay enumerate

instance forall s r. (Show s, FactorialMonoid s, Typeable s) => Enumerable (DescribedParser s ([Bool] -> [Bool])) where
   enumerate = consts (pure <$> [DescribedParser "empty" empty,
                                 DescribedParser "mempty" mempty])
               <> pay (unary $ \r-> DescribedParser ("(pure " ++ shows r ")") (pure r))
               <> pay (unary $ \(DescribedParser d p)-> DescribedParser ("(lookAhead " <> d <> ")") (lookAhead p))
               <> binary " *> " (*>)
               <> binary " <> " (<>)
               <> binary " <|> " (<|>)
      where binary :: String
                   -> (forall g. Rank2.Functor g => Parser g s ([Bool] -> [Bool]) -> Parser g s ([Bool] -> [Bool])
                                                    -> Parser g s ([Bool] -> [Bool]))
                   -> Enumerate (DescribedParser s ([Bool] -> [Bool]))
            binary nm op = (\(Free (DescribedParser d1 p1, DescribedParser d2 p2))-> DescribedParser (d1 <> nm <> d2) (op p1 p2))
                           <$> pay enumerate

instance (Ord s, Enumerable s) => Enumerable (s -> Bool) where
   enumerate = pay (unary (<=))
               <> pay (unary const)

instance Enumerable ([Bool] -> [Bool]) where
   enumerate = consts [pure id,
                       pure (map not)]
               <> pay (unary const)

instance EqProp Word64 where
   a =-= b = property (a == b)

results = either (const []) id
