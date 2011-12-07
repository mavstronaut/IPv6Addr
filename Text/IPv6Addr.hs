-- | 
-- Module      :  Text.IPv6Addr
-- Copyright   :  (c) Michel Boucey 2011
-- License     :  BSD-style
-- Maintainer  :  michel.boucey@gmail.com
-- Stability   :  provisional
--
-- Dealing with IPv6 address's text representation.
-- Main features are validation against RFC 4291 and canonization
-- in conformation with RFC 5952.

module Text.IPv6Addr
    (
      IPv6Addr
    , IPv6AddrToken(..)
    -- * Validating and canonizing an IPv6 Address
    , isIPv6Addr
    , maybeIPv6Addr
    , maybePureIPv6Addr
    , maybeTokIPv6Addr
    , maybeTokPureIPv6Addr
    , maybeFullIPv6Addr
    -- * Manipulating IPv6 address tokens
    -- ** To IPv6 Address token(s)
    , maybeIPv6AddrToken
    , maybeIPv6AddrTokens
    , ipv4AddrToIPv6AddrTokens
    -- ** Back to Text
    , ipv6TokensToText
    ) where

import Control.Monad (replicateM)
import Data.Char (intToDigit,isDigit,isHexDigit,toLower)
import Data.Function (on)
import Data.List (group,isSuffixOf,elemIndex,elemIndices,intersperse)
import Data.Maybe (fromJust,isJust)
import qualified Data.Text as T
import Data.Text.Read (decimal)
import Numeric (showIntAtBase)

import Text.IPv6Addr.Types
import Text.IPv6Addr.Internals

-- | Returns Just the text representation of an 'IPv6Addr' validated against
-- RFC 4291 and canonized in conformation with RFC 5952, or Nothing.
--
-- > maybeIPv6Addr "D045::00Da:0fA9:0:0:230.34.110.80" == Just "d045:0:da:fa9::e622:6e50"
--
maybeIPv6Addr :: T.Text -> Maybe IPv6Addr
maybeIPv6Addr t = maybeTokIPv6Addr t >>= ipv6TokensToText

-- | Returns Just a pure 'IPv6Addr', or Nothing.
maybePureIPv6Addr :: T.Text -> Maybe IPv6Addr
maybePureIPv6Addr t = maybeTokPureIPv6Addr t >>= ipv6TokensToText

-- | Returns Just a pure and expanded IPv6 address, or Nothing.
maybeFullIPv6Addr :: T.Text -> Maybe IPv6Addr
maybeFullIPv6Addr t = do
    a <- maybeTokPureIPv6Addr t
    ipv6TokensToText $ expandTokens $ fromDoubleColon a

expandTokens :: [IPv6AddrToken] -> [IPv6AddrToken]
expandTokens =
    map expTok
  where expTok AllZeros = SixteenBits tok4x0
        expTok (SixteenBits s) = do
            let ls = T.length s
            if ls < 4
               then SixteenBits (T.replicate (4 - ls) tok0 `T.append` s)
               else SixteenBits s
        expTok t = t

-- | Returns Just one of the valid 'IPv6AddrToken', or Nothing.
maybeIPv6AddrToken :: T.Text -> Maybe IPv6AddrToken
maybeIPv6AddrToken t
    | isJust t' = t'
    | isJust(colon t) = Just Colon
    | isJust(doubleColon t) = Just DoubleColon
    | isJust(ipv4Addr t) = Just (IPv4Addr t)
    | otherwise = Nothing
  where t' = sixteenBits t

-- | Returns the corresponding 'Text' of an IPv6 address token.
ipv6TokenToText :: IPv6AddrToken -> T.Text
ipv6TokenToText (SixteenBits s) = s 
ipv6TokenToText Colon = tokcolon
ipv6TokenToText DoubleColon = tokdcolon
-- "A single 16-bit 0000 field MUST be represented as 0" (RFC 5952, 4.1)
ipv6TokenToText AllZeros = tok0
ipv6TokenToText (IPv4Addr a) = a

-- | Given an arbitrary list of 'IPv6AddrToken', returns the corresponding 'Text'.
ipv6TokensToText :: [IPv6AddrToken] -> Maybe T.Text
ipv6TokensToText l = Just $ T.concat $ map ipv6TokenToText l

-- | Returns True if a list of 'IPv6AddrToken' constitutes a valid IPv6 Address.
isIPv6Addr :: [IPv6AddrToken] -> Bool
isIPv6Addr [] = False
isIPv6Addr [DoubleColon] = True
isIPv6Addr [DoubleColon,SixteenBits tok1] = True
isIPv6Addr tks =
    diffNext tks && (do
        let cdctks = countDoubleColon tks
        let lentks = length tks
        let lasttk = last tks
        let lenconst = (lentks == 15 && cdctks == 0) || (lentks < 15 && cdctks == 1)
        firstValidToken tks &&
            (case countIPv4Addr tks of
                0 -> case lasttk of
                          SixteenBits _ -> lenconst
                          DoubleColon -> lenconst
                          AllZeros -> lenconst
                          otherwise -> False
                1 -> case lasttk of
                          IPv4Addr _ ->
                              (lentks == 13 && cdctks == 0) || (lentks < 12 && cdctks == 1)
                          otherwise -> False
                otherwise -> False))
          where diffNext [_] = True
                diffNext [a,a'] = a /= a'
                diffNext (a:as) = (a /= head as) && diffNext as
                firstValidToken l = 
                    case head l of
                        SixteenBits _ -> True
                        DoubleColon -> True
                        AllZeros -> True
                        otherwise -> False
                countDoubleColon l = length $ elemIndices DoubleColon l

countIPv4Addr tks =
     foldr oneMoreIPv4Addr 0 tks
   where oneMoreIPv4Addr t c = case t of
                                   IPv4Addr _ -> c + 1
                                   otherwise -> c

-- | Returns Just a list of 'IPv6AddrToken', or Nothing.
maybeIPv6AddrTokens :: T.Text -> Maybe [IPv6AddrToken]
maybeIPv6AddrTokens t = mapM maybeIPv6AddrToken $ tokenizeBy ':' t

-- | This is the main function which returns Just the list of a tokenized IPv6
-- address's text representation validated against RFC 4291 and canonized
-- in conformation with RFC 5952, or Nothing.
maybeTokIPv6Addr :: T.Text -> Maybe [IPv6AddrToken]
maybeTokIPv6Addr t = 
    do ltks <- maybeIPv6AddrTokens t
       if isIPv6Addr ltks
          then Just $ (toDoubleColon . ipv4AddrReplacement . fromDoubleColon) ltks
          else Nothing
     where ipv4AddrReplacement ltks' =
               if ipv4AddrRewrite ltks'
                  then init ltks' ++ ipv4AddrToIPv6AddrTokens (last ltks')
                  else ltks'

-- | Returns Just the list of tokenized pure IPv6 address, always rewriting an
-- embedded IPv4 address if present.
maybeTokPureIPv6Addr :: T.Text -> Maybe [IPv6AddrToken]
maybeTokPureIPv6Addr t =
    do ltks <- maybeIPv6AddrTokens t
       if isIPv6Addr ltks
          then Just $ (toDoubleColon . ipv4AddrReplacement . fromDoubleColon) ltks
          else Nothing
     where ipv4AddrReplacement ltks' =
               init ltks' ++ ipv4AddrToIPv6AddrTokens (last ltks')

-- | An embedded IPv4 address have to be rewritten to output a pure IPv6 Address
-- text representation in hexadecimal digits. But some well-known prefixed IPv6
-- addresses have to keep visible in their text representation the fact that
-- they deals with IPv4 to IPv6 transition process (RFC 5952 Section 5):
--
-- IPv4-compatible IPv6 address like "::1.2.3.4"
--
-- IPv4-mapped IPv6 address like "::ffff:1.2.3.4"
--
-- IPv4-translated address like "::ffff:0:1.2.3.4"
--
-- IPv4-translatable address like "64:ff9b::1.2.3.4"
--
-- ISATAP address like "fe80::5efe:1.2.3.4"
--
ipv4AddrRewrite :: [IPv6AddrToken] -> Bool
ipv4AddrRewrite tks =
    case last tks of
        IPv4Addr _ -> do
            let itks = init tks
            (itks == [DoubleColon]
             || itks == [DoubleColon,SixteenBits tokffff,Colon]
             || itks == [DoubleColon,SixteenBits tokffff,Colon,AllZeros,Colon]
             || itks == [SixteenBits tok64,Colon,SixteenBits tokff9b,DoubleColon]
             || [SixteenBits tok200,Colon,SixteenBits tok5efe,Colon] `isSuffixOf` itks
             || [AllZeros,Colon,SixteenBits tok5efe,Colon] `isSuffixOf` itks
             || [DoubleColon,SixteenBits tok5efe,Colon] `isSuffixOf` itks)
        otherwise -> False

-- | Rewrites Just an embedded 'IPv4Addr' into the corresponding list of pure
-- IPv6Addr tokens, or returns an empty list.
--
-- > ipv4AddrToIPv6AddrTokens (IPv4Addr "127.0.0.1") == [SixteenBits "7f0",Colon,SixteenBits "1"]
--
ipv4AddrToIPv6AddrTokens :: IPv6AddrToken -> [IPv6AddrToken]
ipv4AddrToIPv6AddrTokens t =
    case t of
        IPv4Addr a -> do
            let m = toHex a
            [fromJust $ sixteenBits ((!!) m 0 `T.append` addZero ((!!) m 1))
             ,Colon
             ,fromJust $ sixteenBits ((!!) m 2 `T.append` addZero ((!!) m 3))]
        otherwise -> []
      where toHex a = map (\x -> T.pack $ showIntAtBase 16 intToDigit (read (T.unpack x)::Int) "") $ T.split (=='.') a
            addZero d = if T.length d == 1 then tok0 `T.append` d else d

fromDoubleColon :: [IPv6AddrToken] -> [IPv6AddrToken]
fromDoubleColon tks = 
    if DoubleColon `notElem` tks then tks
    else do
        let s = splitAt (fromJust $ elemIndex DoubleColon tks) tks
        let fsts = fst s
        let snds = if length(snd s) >= 1 then tail(snd s) else []
        let fste = if null fsts then [] else fsts ++ [Colon]
        let snde = if null snds then [] else Colon : snds
        fste ++ allZerosTokensReplacement(quantityOfAllZerosTokenToReplace tks) ++ snde
      where quantityOfAllZerosTokenToReplace x =
                ntks tks - foldl (\c x -> if (x /= DoubleColon) && (x /= Colon) then c+1 else c) 0 x
              where
                ntks tks = if countIPv4Addr tks == 1 then 7 else 8
            allZerosTokensReplacement x = intersperse Colon (replicate x AllZeros)

toDoubleColon :: [IPv6AddrToken] -> [IPv6AddrToken]
toDoubleColon tks =
    zerosToDoubleColon tks (zerosRunToReplace $ zerosRunsList tks)
  where
    zerosToDoubleColon :: [IPv6AddrToken] -> (Int,Int) -> [IPv6AddrToken]
    -- No all zeros token, so no double colon replacement...
    zerosToDoubleColon ls (_,0) = ls
    -- "The symbol '::' MUST NOT be used to shorten just one 16-bit 0 field" (RFC 5952 4.2.2)
    zerosToDoubleColon ls (_,1) = ls
    zerosToDoubleColon ls (i,l) =
        let ls' = filter (/= Colon) ls
        in intersperse Colon (take i ls') ++ [DoubleColon] ++ intersperse Colon (drop (i+l) ls')
    zerosRunToReplace t =
        let l = longestLengthZerosRun t
        in (firstLongestZerosRunIndex t l,l)
      where firstLongestZerosRunIndex x y = sum . snd . unzip $ takeWhile (/=(True,y)) x
            longestLengthZerosRun x =
                maximum $ map longest x
              where longest t = case t of
                                    (True,i) -> i
                                    otherwise -> 0
    zerosRunsList x =
        map helper $ groupZerosRuns x
      where
        helper h =
            if head h == AllZeros
               then (True,lh)
               else (False,lh)
          where lh = length h
        groupZerosRuns = group . filter (/= Colon)
