---
layout: post
title:  "Rest api in Haskell"
imgdir:  "restapihaskell"
date:   2017-03-05 16:00:00 +0100
excerpt: "Simple json rest api written in haskell using scotty library and Postgresql."
tags: haskell api webapp
---
Recently I've discovered world of functional programming and was really surprised by the amount of fun which it gives back. Not without a reason Haskell is the king of weekend programming:

{% include image.html image='haskelltags.png' caption='Source: <a href="https://stackoverflow.blog/2017/02/07/what-programming-languages-weekends/">Stackoverflow blog</a>' %}

I want to show you how to build simple rest api with Haskell.

# Preparing

You will need:
+ [stack](https://docs.haskellstack.org/en/stable/README/) - cross platform program for developing Haskell projects. It manages packages and builds your project
+ [postgresql](https://www.postgresql.org/) - open source database system. Install locally or go big and run it on some server.

# Execution
run:
{% highlight bash linenos=table %}
stack new projectname
{% endhighlight %}

to set up all files needed by stack and go to that folder.

Then in projectname.cabal you need to add some libraries.
Find executable projectname and add:

{% highlight ruby linenos=table %}
executable projectname
    hs-source-dirs: ... #what you want
    main-is: Main.hs
    other-extensions: OverloadedStrings
    build-depends:  base,
                    scotty,
                    aeson,
                    postgresql-simple
    default-language: Haskell2010
{% endhighlight %}

then run: 
{% highlight bash linenos=table %}
stack build
{% endhighlight %} 

to install all dependencies.
Move to folder with Main.sh and let's start programming!

## Haskell time!
Firstly, let's make super simple api to check if everything is correct:
{% highlight Haskell linenos=table %}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty

server :: ScottyM ()
server = do
    get "/alive" $ do
        text "yep!"

main :: IO ()
main = do
    scotty 1234 server
{% endhighlight %}


and run:
{% highlight bash linenos=table %}
stack build
stack exec projectname
{% endhighlight %}
and now check it in your browser! Write in url: localhost:1234/alive and voilà!

(You can install [stack run](https://hackage.haskell.org/package/stack-run) for less typing when you want to build and execute your program!)

## Database setting up
Ok, let's connect to the database! If you have problem with setting up your Postgresql database I recomend visiting [DigitalOcean tutorial](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-postgresql-on-ubuntu-16-04)

I prepared a simple database input for tutorial purposes. It's gonna be a simple todo list.

{% highlight sql linenos=table %}
CREATE TABLE "checklists" (
      "id" SERIAL PRIMARY KEY,
      "title" TEXT
);

insert into checklists (title) values
('backend'),
('shopping');

CREATE TABLE "checklistitems" (
      "id" SERIAL PRIMARY KEY,
      "name" TEXT NOT NULL,
      "finished" BOOLEAN NOT NULL,
      "checklist" INTEGER NOT NULL
);

insert into checklistitems (name, finished, checklist) values
('reformat code', true, 1),
('user login', true, 1),
('add CI', false, 1),
('tomato', false, 2),
('potato', false, 2);
{% endhighlight %}

## Connect to database
To do this, we need to import PostgreSQL.Simple library

{% highlight haskell linenos=table %}
import Database.PostgreSQL.Simple
{% endhighlight %}

and make a connection:

{% highlight haskell linenos=table %}
conn <- connectPostgreSQL ("host='127.0.0.1' user='haxor' dbname='haxordb' password='pass'")
{% endhighlight %}

Now we should create Checklist and ChecklistItem classes:

{% highlight haskell linenos=table %}
{-# LANGUAGE DeriveGeneric #-}

...

data Checklist = Checklist { checklistId :: Maybe Int,
    title :: String,
    checklistItems :: [ChecklistItem]} deriving (Show, Generic)
{% endhighlight %}

Simple class definition. We use DeriveGeneric for "generic" programming. In next lines of code it will become handy.


{% highlight haskell linenos=table %}
instance FromRow Checklist where
    fromRow = Checklist <$> field <*> field <*> pure []

instance ToRow Checklist where
    toRow c = [toField $ title c]
{% endhighlight %}

In case of creating object from SQL query we need to list all fields of our class. Haskell won't let us create object without setting up all fields. But we cannot get checklist and checklist items in one single query, so we need to pass `pure []` as our `checklistItems` list. When we want to make oposite: include our object into SQL queries - we have full control about which fields we want to pass.

{% highlight haskell linenos=table %}
instance ToJSON Checklist
instance FromJSON Checklist
{% endhighlight %}

Here we use `{-# LANGUAGE DeriveGeneric #-}` language extension. GHC implements this for us.

The same story goes for ChecklistItem

{% highlight haskell linenos=table %}
data ChecklistItem = ChecklistItem { checklistItemId :: Maybe Int,
    itemText :: String,
    finished :: Bool,
    checklist :: Int } deriving (Show, Generic)

instance FromRow ChecklistItem where
    fromRow = ChecklistItem <$> field <*> field <*> field <*> field

instance ToRow ChecklistItem where
    toRow i = [toField $ itemText i, toField $ finished i, toField $ checklist i]

instance ToJSON ChecklistItem

instance FromJSON ChecklistItem
{% endhighlight %}

## Database queries
Ok, let's do some queries to our server!

{% highlight haskell linenos=table %}
import Control.Monad.IO.Class

server :: Connection -> ScottyM()
server conn = do
    get "/checklists" $ do
        checklists <- liftIO (query_ conn "select id, title from checklists" :: IO [Checklist])
        json checklists

main :: IO ()
main = do
    conn <- connectPostgreSQL ("host='127.0.0.1' user='blog' dbname='blog' password='pass'")
    scotty 1234 $ server conn
{% endhighlight %}

It seems working, but we get Checklists without items. How to fix it?

{% highlight haskell linenos=table %}
server :: Connection -> ScottyM()
server conn = do
    get "/checklists" $ do
        checklists <- liftIO (query_ conn "select id, title from checklists" :: IO [Checklist])
        checkWithItems <- liftIO (mapM (setArray conn) checklists)
        json checkWithItems

setArray :: Connection -> Checklist -> IO Checklist
setArray conn check = do
    let queryText = "select id, name, finished, checklist from checklistitems where checklist = (?)"
    items <- liftIO (query conn queryText (Only $ checklistId check) :: IO [ChecklistItem])
    return check { checklistItems = items }
{% endhighlight %}
Notice that this time we use `query` instead of `query_`. `query` makes "query substitution": it takes `ToRow` instance and inserts values in places of '?' inside query string.

Now when we hit localhost:1234/checklists it will return:
{% highlight json linenos=table %}
[
  {
    "checklistItems": [
      {
        "checklist": 1,
        "checklistItemId": 1,
        "finished": true,
        "itemText": "reformat code"
      },
      {
        "checklist": 1,
        "checklistItemId": 2,
        "finished": true,
        "itemText": "user login"
      },
      {
        "checklist": 1,
        "checklistItemId": 3,
        "finished": false,
        "itemText": "add CI"
      }
    ],
    "checklistId": 1,
    "title": "backend"
  },
  {
    "checklistItems": [
      {
        "checklist": 2,
        "checklistItemId": 4,
        "finished": false,
        "itemText": "tomato"
      },
      {
        "checklist": 2,
        "checklistItemId": 5,
        "finished": false,
        "itemText": "potato"
      }
    ],
    "checklistId": 2,
    "title": "shopping"
  }
]
{% endhighlight %}

Now let's implement post method for checklist items:

{% highlight haskell linenos=table %}
server conn = do
    ...
    post "/checklistitems" $ do
        item <- jsonData :: ActionM ChecklistItem
        newItem <- liftIO (insertChecklist conn item)
        json newItem

insertChecklist :: Connection -> ChecklistItem -> IO ChecklistItem
insertChecklist conn item = do
    let insertQuery = "insert into checklistitems (name, finished, checklist) values (?, ?, ?) returning id"
    [Only id] <- query conn insertQuery item
    return item { checklistItemId = id }
{% endhighlight %}

Now we can create new ChecklistItem and our api returning new object with assigned id. 
# Sum up
Ok, we've made a simple json rest api in Haskell with get and post methods! Here is a full source:
{% highlight haskell linenos=table %}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import Web.Scotty
import Data.Aeson (FromJSON, ToJSON)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.ToRow
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.ToField
import GHC.Generics
import Control.Monad.IO.Class

server :: Connection -> ScottyM()
server conn = do
    get "/checklists" $ do
        checklists <- liftIO (query_ conn "select id, title from checklists" :: IO [Checklist])
        checkWithItems <- liftIO (mapM (setArray conn) checklists)
        json checkWithItems
    post "/checklistitems" $ do
        item <- jsonData :: ActionM ChecklistItem
        newItem <- liftIO (insertChecklist conn item)
        json newItem

selectChecklistQuery = "select id, name, finished, checklist from checklistitems where checklist = (?)"
insertItemsQuery = "insert into checklistitems (name, finished, checklist) values (?, ?, ?) returning id"

setArray :: Connection -> Checklist -> IO Checklist
setArray conn check = do
    items <- liftIO (query conn selectChecklistQuery (Only $ checklistId check) :: IO [ChecklistItem])
    return check { checklistItems = items }

insertChecklist :: Connection -> ChecklistItem -> IO ChecklistItem
insertChecklist conn item = do
    [Only id] <- query conn insertItemsQuery item
    return item { checklistItemId = id }

main :: IO ()
main = do
    conn <- connectPostgreSQL ("host='127.0.0.1' user='blog' dbname='blog' password='pass'")
    scotty 1234 $ server conn



data Checklist = Checklist { checklistId :: Maybe Int,
    title :: String,
    checklistItems :: [ChecklistItem]} deriving (Show, Generic)

instance FromRow Checklist where
    fromRow = Checklist <$> field <*> field <*> pure []
instance ToRow Checklist where
    toRow c = [toField $ title c]
instance ToJSON Checklist
instance FromJSON Checklist

data ChecklistItem = ChecklistItem { checklistItemId :: Maybe Int,
    itemText :: String,
    finished :: Bool,
    checklist :: Int } deriving (Show, Generic)

instance FromRow ChecklistItem where
    fromRow = ChecklistItem <$> field <*> field <*> field <*> field
instance ToRow ChecklistItem where
    toRow i = [toField $ itemText i, toField $ finished i, toField $ checklist i]
instance ToJSON ChecklistItem
instance FromJSON ChecklistItem
{% endhighlight %}
