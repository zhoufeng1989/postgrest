{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
module PostgREST.App where
-- module PostgREST.App (
--   app
-- , sqlError
-- , isSqlError
-- , contentTypeForAccept
-- , jsonH
-- , TableOptions(..)
-- , parsePostRequest
-- , rr
-- , bb
-- ) where

import           Control.Applicative
import           Control.Arrow             ((***))
import           Control.Monad             (join)
import           Data.Bifunctor            (first)
import qualified Data.ByteString.Char8     as BS
import qualified Data.ByteString.Lazy      as BL
import qualified Data.Csv                  as CSV
import           Data.Functor.Identity
import qualified Data.HashMap.Strict       as M
import           Data.List                 (find, sortBy, delete, transpose)
import           Data.Maybe                (fromMaybe, fromJust, isJust, isNothing)
import           Data.Ord                  (comparing)
import           Data.Ranged.Ranges        (emptyRange)
import qualified Data.Set                  as S
import           Data.String.Conversions   (cs)
import           Data.Text                 (Text, replace, strip)
import           Data.Tree
--import           Data.Foldable             (forlrM)

import           Text.Parsec.Error
import           Text.ParserCombinators.Parsec (parse)

import           Network.HTTP.Base         (urlEncodeVars)
import           Network.HTTP.Types.Header
import           Network.HTTP.Types.Status
import           Network.HTTP.Types.URI    (parseSimpleQuery)
import           Network.Wai
import           Network.Wai.Parse         (parseHttpAccept)

import           Data.Aeson
import           Data.Aeson.Types (emptyArray)
import           Data.Monoid
import qualified Data.Vector               as V
import qualified Hasql                     as H
import qualified Hasql.Backend             as B
import qualified Hasql.Postgres            as P

import           PostgREST.Config          (AppConfig (..))
import           PostgREST.Parsers
import           PostgREST.PgQuery
import           PostgREST.PgStructure
import           PostgREST.QueryBuilder
import           PostgREST.RangeQuery
import           PostgREST.Types
import           PostgREST.Auth (tokenJWT)

import           Prelude

app :: DbStructure -> AppConfig -> BL.ByteString -> Request -> H.Tx P.Postgres s Response
app dbstructure conf reqBody req =
  case (path, verb) of

    ([table], "GET") ->
      if range == Just emptyRange
      then return $ responseLBS status416 [] "HTTP Range error"
      else
        case query of
          Left e -> return $ responseLBS status400 [("Content-Type", "application/json")] $ cs e
          Right qs -> do
            let q = B.Stmt
                    (
                      wrapQuery qs [
                        (if hasPrefer "count=none" then countNoneF else countAllF),
                        countF,
                        (case contentType of
                          "text/csv" -> asCsvF -- TODO check when in csv mode if the header is correct when requesting nested data
                          _     -> asJsonF
                        )
                      ] range
                    )
                    V.empty True
            row <- H.maybeEx q
            let (tableTotal, queryTotal, body) = fromMaybe (Just (0::Int), 0::Int, Just "" :: Maybe BL.ByteString) row
                to = frm+queryTotal-1
                contentRange = contentRangeH frm to tableTotal
                status = rangeStatus frm to tableTotal
                canonical = urlEncodeVars
                  . sortBy (comparing fst)
                  . map (join (***) cs)
                  . parseSimpleQuery
                  $ rawQueryString req
            return $ responseLBS status
              [contentTypeH, contentRange,
                ("Content-Location",
                  "/" <> cs table <>
                    if Prelude.null canonical then "" else "?" <> cs canonical
                )
              ] (fromMaybe "[]" body)

        where
            frm = fromMaybe 0 $ rangeOffset <$> range
            apiRequest = parseGetRequest table req
                     >>= first formatRelationError . addRelations schema allRels Nothing
                     >>= addJoinConditions schema allCols
            query = requestToQuery schema <$> apiRequest

    ([table], "POST") -> do
      let echoRequested = hasPrefer "return=representation"
      case insertQuery of
        Left e -> return $ responseLBS status400 [("Content-Type", "application/json")] $ cs e
        Right qs -> do
          let isSingle = either (const False) id returnSingle
              pKeys = map pkName $ filter (filterPk schema table) allPrKeys
              q = B.Stmt
                    (
                      wrapQuery qs [
                        (if isSingle then locationF pKeys else "null"),
                        "null", -- countF,
                        (
                          if echoRequested
                          then
                            case contentType of
                               "text/csv" -> asCsvF
                               _     -> if isSingle then asJsonSingleF else asJsonF
                          else "null"
                        )
                      ] Nothing
                    )
                    V.empty True

          row <- H.maybeEx q
          let (locationRaw, _ {-- queryTotal --}, bodyRaw) = fromMaybe (Just "" :: Maybe BL.ByteString, Just (0::Int), Just "" :: Maybe BL.ByteString) row
              body = fromMaybe "[]" bodyRaw
              locationH = fromMaybe "" locationRaw
          return $ responseLBS status201
            [
              contentTypeH,
              (hLocation, "/" <> cs table <> "?" <> cs locationH)
            ]
            $ if echoRequested then body else ""
      where
        res = parsePostRequest table req reqBody
        apiRequest = snd <$> res
        returnSingle = fst <$> res
        insertQuery = requestToQuery schema <$> apiRequest

    ([table], "PUT") ->
      handleJsonObj reqBody $ \obj -> do
        let qt = qualify table
            pKeys = map pkName $ filter (filterPk schema table) allPrKeys
            specifiedKeys = map (cs . fst) qq
        if S.fromList pKeys /= S.fromList specifiedKeys
          then return $ responseLBS status405 []
            "You must speficy all and only primary keys as params"
          else do
            let tableCols = map (cs . colName) $ filter (filterCol schema table) allCols
                cols = map cs $ M.keys obj
            if S.fromList tableCols == S.fromList cols
              then do
                let vals = M.elems obj
                H.unitEx $ iffNotT
                  (whereT qt qq $ update qt cols vals)
                  (insertSelect qt cols vals)
                return $ responseLBS status204 [ jsonH ] ""

              else return $ if Prelude.null tableCols
                then responseLBS status404 [] ""
                else responseLBS status400 []
                  "You must specify all columns in PUT request"

    ([table], "PATCH") ->
      handleJsonObj reqBody $ \obj -> do
        let qt = qualify table
            up = returningStarT
              . whereT qt qq
              $ update qt (map cs $ M.keys obj) (M.elems obj)
            patch = withT up "t" $ B.Stmt
              "select count(t), array_to_json(array_agg(row_to_json(t)))::character varying"
              V.empty True

        row <- H.maybeEx patch
        let (queryTotal, body) =
              fromMaybe (0 :: Int, Just "" :: Maybe Text) row
            r = contentRangeH 0 (queryTotal-1) (Just queryTotal)
            echoRequested = hasPrefer "return=representation"
            s = case () of _ | queryTotal == 0 -> status404
                             | echoRequested -> status200
                             | otherwise -> status204
        return $ responseLBS s [ jsonH, r ] $ if echoRequested then cs $ fromMaybe "[]" body else ""

    ([table], "DELETE") -> do
      let qt = qualify table
          del = countT
            . returningStarT
            . whereT qt qq
            $ deleteFrom qt
      row <- H.maybeEx del
      let (Identity deletedCount) = fromMaybe (Identity 0 :: Identity Int) row
      return $ if deletedCount == 0
        then responseLBS status404 [] ""
        else responseLBS status204 [("Content-Range", "*/"<> cs (show deletedCount))] ""

    (["rpc", proc], "POST") -> do
      let qi = QualifiedIdentifier schema (cs proc)
      exists <- doesProcExist schema proc
      if exists
        then do
          let call = B.Stmt "select " V.empty True <>
                asJson (callProc qi $ fromMaybe M.empty (decode reqBody))
          bodyJson :: Maybe (Identity Value) <- H.maybeEx call
          returnJWT <- doesProcReturnJWT schema proc
          return $ responseLBS status200 [jsonH]
                 (let body = fromMaybe emptyArray $ runIdentity <$> bodyJson in
                    if returnJWT
                    then "{\"token\":\"" <> cs (tokenJWT jwtSecret body) <> "\"}"
                    else cs $ encode body)
        else return $ responseLBS status404 [] ""

      -- check that proc exists
      -- check that arg names are all specified
      -- select * from public.proc(a := "foo"::undefined) where whereT limit limitT

    ([], _) -> do
      Identity (dbrole :: Text) <- H.singleEx $ [H.stmt|SELECT current_user|]
      let body = encode $ filter (filterTableAcl dbrole) $ filter ((cs schema==).tableSchema) allTabs
      return $ responseLBS status200 [jsonH] $ cs body

    ([table], "OPTIONS") -> do
      let cols = filter (filterCol schema table) allCols
          pkeys = map pkName $ filter (filterPk schema table) allPrKeys
          body = encode (TableOptions cols pkeys)
      return $ responseLBS status200 [jsonH, allOrigins] $ cs body

    (_, _) ->
      return $ responseLBS status404 [] ""

  where
    allTabs = tables dbstructure
    allRels = relations dbstructure
    allCols = columns dbstructure
    allPrKeys = primaryKeys dbstructure
    filterCol sc table (Column{colSchema=s, colTable=t}) =  s==sc && table==t
    filterCol _ _ _ =  False
    filterPk sc table pk = sc == pkSchema pk && table == pkTable pk

    filterTableAcl :: Text -> Table -> Bool
    filterTableAcl r (Table{tableAcl=a}) = r `elem` a
    path          = pathInfo req
    verb          = requestMethod req
    qq            = queryString req
    qualify       = QualifiedIdentifier schema
    hdrs          = requestHeaders req
    lookupHeader  = flip lookup hdrs
    hasPrefer val = any (\(h,v) -> h == "Prefer" && v == val) hdrs
    accept        = lookupHeader hAccept
    schema        = cs $ configSchema conf
    jwtSecret     = (cs $ configJwtSecret conf) :: Text
    range         = rangeRequested hdrs
    allOrigins    = ("Access-Control-Allow-Origin", "*") :: Header
    contentType   = fromMaybe "application/json" $ contentTypeForAccept accept
    contentTypeH  = (hContentType, contentType)

sqlError :: t
sqlError = undefined

isSqlError :: t
isSqlError = undefined

rangeStatus :: Int -> Int -> Maybe Int -> Status
rangeStatus _ _ Nothing = status200
rangeStatus frm to (Just total)
  | frm > total            = status416
  | (1 + to - frm) < total = status206
  | otherwise               = status200

contentRangeH :: Int -> Int -> Maybe Int -> Header
contentRangeH frm to total =
    ("Content-Range", cs headerValue)
    where
      headerValue   = rangeString <> "/" <> totalString
      rangeString
        | totalNotZero && fromInRange = show frm <> "-" <> cs (show to)
        | otherwise = "*"
      totalString   = fromMaybe "*" (show <$> total)
      totalNotZero  = fromMaybe True ((/=) 0 <$> total)
      fromInRange   = frm <= to

jsonMT :: BS.ByteString
jsonMT = "application/json"

csvMT :: BS.ByteString
csvMT = "text/csv"

allMT :: BS.ByteString
allMT = "*/*"

jsonH :: Header
jsonH = (hContentType, jsonMT)

contentTypeForAccept :: Maybe BS.ByteString -> Maybe BS.ByteString
contentTypeForAccept accept
  | isNothing accept || has allMT || has jsonMT = Just jsonMT
  | has csvMT = Just csvMT
  | otherwise = Nothing
  where
    Just acceptH = accept
    findInAccept = flip find $ parseHttpAccept acceptH
    has          = isJust . findInAccept . BS.isPrefixOf

bodyForAccept :: BS.ByteString -> QualifiedIdentifier  -> StatementT
bodyForAccept contentType table
  | contentType == csvMT = asCsvWithCount table
  | otherwise = asJsonWithCount -- defaults to JSON

handleJsonObj :: BL.ByteString -> (Object -> H.Tx P.Postgres s Response)
              -> H.Tx P.Postgres s Response
handleJsonObj reqBody handler = do
  let p = eitherDecode reqBody
  case p of
    Left err ->
      return $ responseLBS status400 [jsonH] jErr
      where
        jErr = encode . object $
          [("message", String $ "Failed to parse JSON payload. " <> cs err)]
    Right (Object o) -> handler o
    Right _ ->
      return $ responseLBS status400 [jsonH] jErr
      where
        jErr = encode . object $
          [("message", String "Expecting a JSON object")]

parseCsvCell :: BL.ByteString -> Value
parseCsvCell s = if s == "NULL" then Null else String $ cs s

formatRelationError :: Text -> Text
formatRelationError e = cs $ encode $ object [
  "mesage" .= ("could not find foreign keys between these entities"::String),
  "details" .= e]
formatParserError :: ParseError -> Text
formatParserError e = cs $ encode $ object [
  "message" .= message,
  "details" .= details]
  where
     message = show (errorPos e)
     details = strip $ replace "\n" " " $ cs
       $ showErrorMessages "or" "unknown parse error" "expecting" "unexpected" "end of input" (errorMessages e)

parsePostRequest :: NodeName -> Request -> BL.ByteString -> Either Text (Bool, ApiRequest)
parsePostRequest rootTableName httpRequest reqBody =
  (,) <$> returnSingle <*> node
  where
    node = Node <$> apiNode <*> pure []
    apiNode = (,) <$> (Insert rootTableName <$> flds <*> vals) <*> pure (rootTableName, Nothing)
    flds =  join $ first formatParserError . mapM (parseField . cs) <$> (fst <$> parsed)
    vals = snd <$> parsed
    parseField f = parse pField ("failed to parse field <<"++f++">>") f
    parsed :: Either Text ([Text],[[Value]])
    parsed = parseRequestBody isCsv reqBody
    returnSingle = (==1) . length . snd <$> parsed -- not quite correct qhen the user send single row but in an array
    hdrs          = requestHeaders httpRequest
    lookupHeader  = flip lookup hdrs
    --rootTableName = cs $ head $ pathInfo httpRequest -- TODO unsafe head
    isCsv = lookupHeader "Content-Type" == Just csvMT

parseRequestBody :: Bool -> BL.ByteString -> Either Text ([Text],[[Value]])
parseRequestBody isCsv reqBody = first cs $
  checkStructure =<<
  if isCsv
  then do
    rows <- (map V.toList . V.toList) <$> CSV.decode CSV.NoHeader reqBody
    if null rows then Left "CSV requires header" -- TODO! should check if length rows > 1 (header and 1 row)
      else Right (head rows, (map $ map $ parseCsvCell . cs) (tail rows))
  else eitherDecode reqBody >>= convertJson
  where
    checkStructure :: ([Text], [[Value]]) -> Either String ([Text], [[Value]])
    checkStructure v =
      if headerMatchesContent v
      then Right v
      else
        if isCsv
        then Left "CSV header does not match rows length"
        else Left "The number of keys in objects do not match"

    headerMatchesContent :: ([Text], [[Value]]) -> Bool
    headerMatchesContent (header, vals) = all ( (headerLength ==) . length) vals
      where headerLength = length header

convertJson :: Value -> Either String ([Text],[[Value]])
convertJson v = (,) <$> (header <$> normalized) <*> (vals <$> normalized)
  where
    invalidMsg = "Expecting single JSON object or JSON array of objects"
    normalized :: Either String [(Text, [Value])]
    normalized = groupByKey =<< normalizeValue v

    vals :: [(Text, [Value])] -> [[Value]]
    vals = transpose . map snd

    header :: [(Text, [Value])] -> [Text]
    header = map fst

    groupByKey :: Value -> Either String [(Text,[Value])]
    groupByKey (Array a) = M.toList . foldr (M.unionWith (++)) (M.fromList []) <$> maps
      where
        maps :: Either String [M.HashMap Text [Value]]
        maps = mapM getElems $ V.toList a
        getElems (Object o) = Right $ M.map (:[]) o
        getElems _ = Left invalidMsg
    groupByKey _ = Left invalidMsg

    normalizeValue :: Value -> Either String Value
    normalizeValue val =
      case val of
        Object obj  -> Right $ Array (V.fromList[Object obj])
        a@(Array _) -> Right a
        _ -> Left invalidMsg

parseGetRequest :: NodeName -> Request -> Either Text ApiRequest
parseGetRequest rootTableName httpRequest =
  first formatParserError $ foldr addFilter <$> (addOrder <$> apiRequest <*> ord) <*> flts
  where
    apiRequest = parse (pRequestSelect rootTableName) ("failed to parse select parameter <<"++selectStr++">>") $ cs selectStr
    addOrder (Node (q,i) f) o = Node (q{order=o}, i) f
    flts = mapM pRequestFilter whereFilters
    --rootTableName = cs $ head $ pathInfo httpRequest -- TODO unsafe head
    qString = [(cs k, cs <$> v)|(k,v) <- queryString httpRequest]
    orderStr = join $ lookup "order" qString
    ord = traverse (parse pOrder ("failed to parse order parameter <<"++fromMaybe "" orderStr++">>")) orderStr
    selectStr = fromMaybe "*" $ fromMaybe (Just "*") $ lookup "select" qString --in case the parametre is missing or empty we default to *
    whereFilters = [ (k, fromJust v) | (k,v) <- qString, k `notElem` ["select", "order"], isJust v ]

addFilter :: (Path, Filter) -> ApiRequest -> ApiRequest
addFilter ([], flt) (Node (q@(Select {where_=flts}), i) forest) = Node (q {where_=flt:flts}, i) forest
addFilter (path, flt) (Node rn forest) =
  case targetNode of
    Nothing -> Node rn forest -- the filter is silenty dropped in the Request does not contain the required path
    Just tn -> Node rn (addFilter (remainingPath, flt) tn:restForest)
  where
    targetNodeName:remainingPath = path
    (targetNode,restForest) = splitForest targetNodeName forest
    splitForest name forst =
      case maybeNode of
        Nothing -> (Nothing,forest)
        Just node -> (Just node, delete node forest)
      where maybeNode = find ((name==).fst.snd.rootLabel) forst


data TableOptions = TableOptions {
  tblOptcolumns :: [Column]
, tblOptpkey    :: [Text]
}

instance ToJSON TableOptions where
  toJSON t = object [
      "columns" .= tblOptcolumns t
    , "pkey"   .= tblOptpkey t ]
