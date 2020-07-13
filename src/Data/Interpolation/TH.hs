module Data.Interpolation.TH
  ( makeInterpolatorSumInstance
  , withUninterpolated
  , withPolymorphic
  , deriveUninterpolated
  ) where

import Prelude
import Data.Char (toLower)
import Data.Either.Validation (Validation (Success))
import Data.List (dropWhileEnd)
import Data.Profunctor.Product.Default (Default, def)
import Data.Semigroup ((<>))
import Data.Sequences (catMaybes, replicateM, singleton, stripPrefix)
import Data.Traversable (for)
import Language.Haskell.TH
  ( Con (NormalC, RecC)
  , Dec (DataD, NewtypeD, TySynD)
  , Info (TyConI)
  , Name
  , Q
  , Type (AppT, ConT, VarT)
  , isInstance
  , lookupTypeName
  , mkName
  , nameBase
  , newName
  , pprint
  , reify
  , reportError
  )
import qualified Language.Haskell.TH.Lib as TH
import Language.Haskell.TH.Syntax (returnQ)


import Data.Interpolation (FromTemplateValue, Interpolator (Interpolator), runInterpolator)

extractSumConstructorsAndNumFields :: Name -> Q [(Name, Int)]
extractSumConstructorsAndNumFields ty = do
  reify ty >>= \ case
    TyConI (NewtypeD _ _ _ _ c _) -> singleton <$> extractConstructor c
    TyConI (DataD _ _ _ _ cs _) -> traverse extractConstructor cs
    other -> fail $ "can't extract constructors: " <> show other
  where
    extractConstructor = \ case
      NormalC n fs -> pure (n, length fs)
      other -> fail $ "won't extract constructors: " <> show other <> " - sum types only"

-- |Make an instance of 'Default' for 'Interpolator' of an ADT. Can't do it for an arbitrary
-- Profunctor p because of partial functions. This splice is meant to be used in conjunction with
-- 'makeAdaptorAndInstance' for records as a way to project 'Default' instances down to all leaves.
--
-- @
--
--  data Foo' a b = Foo1 a | Foo2 b
--  makeInterpolatorSumInstance ''Foo'
--
-- @
--
-- @
--
--  instance (Default Interpolator a1 b1, Default Interpolator a2 b2) => Default Interpolator (Foo' a1 a2) (Foo' b1 b2) where
--    def = Interpolator $ \ case
--      Foo1 x -> Foo1 <$> runInterpolator def x
--      Foo2 x -> Foo2 <$> runInterpolator def x
--
-- @
makeInterpolatorSumInstance :: Name -> Q [Dec]
makeInterpolatorSumInstance tyName = do
  cs <- extractSumConstructorsAndNumFields tyName
  (contextConstraints, templateVars, identityVars) <- fmap (unzip3 . mconcat) $ for cs $ \ (_, i) -> replicateM i $ do
    a <- newName "a"
    b <- newName "b"
    pure ([t| Default Interpolator $(TH.varT a) $(TH.varT b) |], a, b)
  let appConstructor x y = TH.appT y (TH.varT x)
      templateType = foldr appConstructor (TH.conT tyName) templateVars
      identityType = foldr appConstructor (TH.conT tyName) identityVars
      matches = flip fmap cs $ \ (c, i) -> case i of
        0 -> TH.match (TH.conP c []) (TH.normalB [| pure $ Success $(TH.conE c) |]) []
        1 -> do
          x <- newName "x"
          TH.match (TH.conP c [TH.varP x]) (TH.normalB [| fmap $(TH.conE c) <$> runInterpolator def $(TH.varE x) |]) []
        _ -> fail "can only match sum constructors up to 1 argument"
  sequence
    [ TH.instanceD
        (TH.cxt contextConstraints)
        [t| Default Interpolator $(templateType) $(identityType) |]
        [ TH.funD
            'def
            [TH.clause [] (TH.normalB [| Interpolator $(TH.lamCaseE matches) |]) []]
        ]
    ]

-- |When applied to a simple data type declaration, substitute a fully-polymorphic data type
-- (suffixed with a "prime"), and type aliases for "normal" and "uninterpolated" variants.
--
-- For example, a record or newtype (using record syntax):
--
-- @
--   withUninterpolated [d|
--     data Foo = Foo
--       { fooBar :: String
--       , fooBaz :: Maybe Int
--       } deriving (Eq, Show)
--     |]
-- @
--
-- Is equivalent to:
--
-- @
--   data Foo' bar baz = Foo
--     { fooBar :: bar
--     , fooBaz :: baz
--     } deriving (Eq, Show)
--   type Foo = Foo' String (Maybe Int)
--   type UninterpolatedFoo = Foo' (Uninterpolated String) (Maybe (Uninterpolated Int))
-- @
--
-- __Note:__ the trailing @|]@ of the quasi quote bracket has to be indented or a parse error will occur.
--
-- A simple sum type whose constructors have one argument or less:
--
-- @
--   withUninterpolated [d|
--     data MaybeFoo
--       = AFoo Foo
--       | NoFoo
--       deriving (Eq, Show)
-- @
--
-- Expands to:
--
-- @
--   data MaybeFoo' aFoo
--     = AFoo aFoo
--     | NoFoo
--     deriving (Eq, Show)
--   type MaybeFoo = MaybeFoo' Foo
--   type UninterpolatedMaybeFoo = MaybeFoo' (Foo' (Uninterpolated String) (Maybe (Uninterpolated Int)))
--   -- Note: UninterpolatedMaybeFoo ~ MaybeFoo' UninterpolatedFoo
-- @
--
-- Whenever the type of a field is one for which an instance of 'FromTemplateValue' is present, the
-- type is wrapped in 'Uninterpolated'. Otherwise, an attempt is made to push 'Uninterpolated' down
-- into the field's type, even if it's a type synonym such as one generated by this same macro.
--
-- Note: this splice is equivalent to @withPolymorphic [d|data Foo ... |]@ followed by
-- @deriveUninterpolated ''Foo@.
withUninterpolated :: Q [Dec] -> Q [Dec]
withUninterpolated qDecs = do
  (poly, simple) <- withPolymorphic_ qDecs
  uninterp <- deriveUninterpolated_ simple
  pure $ [poly, simple] <> uninterp


-- |When applied to a simple data type declaration, substitute a fully-polymorphic data type
-- (suffixed with a "prime"), and a simple type alias which matches the supplied declaration.
--
-- This splice does not include the corresponding "Uninterpolated" type, so it can be used separately
-- when needed. For example, if you want to define all your record types first, then define/derive
-- the Uninterpolated types for each. This can be important because the presence of a
-- 'FromTemplateValue' instance, defined before the splice, will affect the shape of the derived
-- Uninterpolated type.
--
-- For example, a record or newtype (using record syntax):
--
-- @
--   withPolymorphic [d|
--     data Foo = Foo
--       { fooBar :: String
--       , fooBaz :: Maybe Int
--       } deriving (Eq, Show)
--     |]
-- @
--
-- Is equivalent to:
--
-- @
--   data Foo' bar baz = Foo
--     { fooBar :: bar
--     , fooBaz :: baz
--     } deriving (Eq, Show)
--   type Foo = Foo' String (Maybe Int)
-- @
--
-- __Note:__ the trailing @|]@ of the quasi quote bracket has to be indented or a parse error will occur.
withPolymorphic :: Q [Dec] -> Q [Dec]
withPolymorphic qDecs = do
  (poly, simple) <- withPolymorphic_ qDecs
  pure [poly, simple]

-- |Given the name of a type alias which specializes a polymorphic type (such as the "simple" type
-- generated by 'withPolymorphic'), generate the corresponding "Uninterpolated" type alias which
-- replaces each simple type with an 'Uninterpolated' form, taking account for which types have
-- 'FromTemplateValue' instances.
--
-- Use this instead of 'withUninterpolated' when you need to define instances for referenced types,
-- and you need flexibility in the ordering of declarations in your module's source.
deriveUninterpolated :: Name -> Q [Dec]
deriveUninterpolated tName =
  reify tName >>= \ case
    TyConI dec -> deriveUninterpolated_ dec
    other -> do
      reportError $ "Can't handle type: " <> show other <> "; expected a \"simple\" type alias"
      pure []

---------------
-- * Internal

-- |From a simple type declaration, generate declarations for the polymorphic type and the simple
-- type alias.
withPolymorphic_ :: Q [Dec] -> Q (Dec, Dec)
withPolymorphic_ qDecs = do
  decs <- qDecs
  case decs of
    -- "data" with a single record constructor:
    [DataD [] tName [] Nothing [RecC cName fields] deriv] -> do
      let con = TH.recC (simpleName cName) (returnQ <$> (fieldToPolyField tName <$> fields))
      primedDecl <- TH.dataD (pure []) (primedName tName) (fieldToTypeVar tName <$> fields) Nothing [con] (returnQ <$> deriv)
      normalSyn <- TH.tySynD (simpleName tName) [] $
        returnQ $ foldl (\ t v -> AppT t (fieldToSimpleType v)) (ConT (primedName tName)) fields
      pure (primedDecl, normalSyn)

    -- "newtype" with a single record constructor:
    [NewtypeD [] tName [] Nothing (RecC cName [field]) deriv] -> do
      -- TODO: use the type name, lower-cased, instead of the field name, for the type var?
      let con = TH.recC (simpleName cName) (returnQ <$> [fieldToPolyField tName field])
      primedDecl <- TH.newtypeD (pure []) (primedName tName) [fieldToTypeVar tName field] Nothing con (returnQ <$> deriv)
      normalSyn <- TH.tySynD (simpleName tName) [] $
        returnQ $ AppT (ConT (primedName tName)) (fieldToSimpleType field)
      pure (primedDecl, normalSyn)

    -- "data" with multiple simple constructors:
    [DataD [] tName [] Nothing constrs deriv] -> do
      let mapConstr = \ case
            NormalC cName [(s, t)] ->
              let vName = niceName tName cName
              in pure (Just (TH.plainTV vName), NormalC cName [(s, VarT vName)], Just t)
            NormalC cName [] ->
              pure (Nothing, NormalC cName [], Nothing)
            other -> fail $ "Can't handle constructor: " <> pprint other

      (vars, constrs', ts) <- unzip3 <$> traverse mapConstr constrs
      primedDecl <- TH.dataD (pure []) (primedName tName) (catMaybes vars) Nothing (returnQ <$> constrs') (returnQ <$> deriv)
      normalSyn <- TH.tySynD (simpleName tName) [] $
        returnQ $ foldl AppT (ConT (primedName tName)) (catMaybes ts)
      pure (primedDecl, normalSyn)

    _ -> do
      fail $ "Can't handle declaration: " <> pprint decs

  where
    -- The same name, with a "'" added to the end:
    primedName n = mkName (nameBase n <> "'")

    -- The same name, in a fresh context:
    simpleName = mkName . nameBase

    -- Remove leading "_" and type name, if either is present:
    unPrefixedFieldName tName = mkName . avoidKeywords . unCap . stripped (unCap $ nameBase tName) . stripped "_" . nameBase

    fieldToTypeVar tName (fName, _, _) = TH.plainTV (unPrefixedFieldName tName fName)
    fieldToPolyField tName (fName, s, _) = (simpleName fName, s, VarT (unPrefixedFieldName tName fName))
    fieldToSimpleType (_, _, t) = t

    niceName prefix = mkName . avoidKeywords. unCap . stripped (nameBase prefix) . nameBase
    avoidKeywords str = if str `elem` likelyKeywords then str <> "_" else str
      where
        likelyKeywords =
          [ "as", "case", "class", "data", "default", "deriving", "do", "else", "family", "forall"
          , "foreign", "if", "in", "import", "infix", "infixl", "infixr", "instance", "hiding"
          , "let", "mdo", "module", "newtype", "of", "proc", "qualified", "rec", "then", "type", "where"
          ]
    stripped prefix str = maybe str id (stripPrefix prefix str)
    unCap = \ case
      c : cs -> toLower c : cs
      other -> other


deriveUninterpolated_ :: Dec -> Q [Dec]
deriveUninterpolated_ dec = do
  case dec of
    TySynD sName [] typ -> do
      uninterp <- TH.tySynD (mkName $ "Uninterpolated" <> nameBase sName) [] (mapUninterp typ)
      pure [uninterp]
    _ -> do
      reportError $ "Can't handle declaration: " <> show dec <> "; expected a \"simple\" type alias"
      pure []

-- Apply the Uninterpolated constructor, pushing it inside an outer type application, and into
-- every type parameter, even in the presence of type synonyms (such as those generated here.)
-- If there is a 'FromTemplateValue' instance for an argument type, that constructor is applied
-- to that type, with its structure left intact.
mapUninterp :: Type -> Q Type
mapUninterp typ = do
  uninterp <- lookupTypeName "Uninterpolated" >>= maybe (fail "Uninterpolated not in scope") returnQ
  let wrap = AppT (ConT uninterp)

      -- Apply only to the _right_ side of (nested) AppTs:
      mapRight :: Type -> Q Type
      mapRight = \ case
        AppT t1@(AppT _ _) t2 -> AppT <$> mapRight t1 <*> mapOne t2
        AppT t1            t2 -> AppT t1 <$> mapOne t2
        t                     -> mapOne t

      mapOne :: Type -> Q Type
      mapOne t = do
        mapped <- isInstance ''FromTemplateValue [t] >>= \ case
          True -> pure $ wrap t
          False -> case t of
            ConT n -> do
              info <- reify n
              case info of
                TyConI (DataD _ _ _ _ _ _) -> pure (ConT n)
                TyConI (NewtypeD _ _ _ _ _ _) -> pure (ConT n)
                TyConI (TySynD _ [] t1) -> mapOne t1
                other -> do
                  reportError $ "Can't handle constructor: " <> pprint other
                  pure $ ConT n
            t1@(AppT _ _) -> mapRight t1
            other -> do
              reportError $ "Can't handle type: " <> pprint other
              pure other

        lookupAlias mapped >>= \ case
          Just uName -> pure $ ConT uName
          Nothing -> pure mapped

      -- Name of the "Uninterpolated..." alias which is already in scope and exactly matches
      -- the given type, if any. This prevents the type aliases for nested types from getting
      -- out of hand, both in Haddock and in compile errors.
      lookupAlias :: Type -> Q (Maybe Name)
      lookupAlias t =
        case constrName t of
          Nothing -> pure Nothing
          Just cName -> do
            let uninterpName = "Uninterpolated" <> dropWhileEnd (== '\'') (nameBase cName)
            lookupTypeName uninterpName >>= \ case
              Nothing -> pure Nothing
              Just uName -> do
                uInfo <- reify uName
                case uInfo of
                  TyConI (TySynD _ [] namedT) | namedT == t -> do
                    pure $ Just uName
                  _ -> do
                    pure Nothing

      -- Name of the constructor at the bottom-left of a chain of AppT; that is, the type
      -- constructor being applied to a series of argument types, if that's what it looks like.
      constrName :: Type -> Maybe Name
      constrName = \ case
        ConT name -> Just name
        AppT t _ -> constrName t
        _ -> Nothing


  mapRight typ
