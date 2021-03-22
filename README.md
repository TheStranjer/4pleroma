# Introduction

4pleroma is a Ruby 3.0 script to pull images from one or more 4chan boards and uploads them. This is a work in progress (WIP) and has evolved from a very simple script that originally uploaded all of them, to one where a list of badwords excluded threads that used some of the more disgusting words found on that site, to one that has a sophisticated (by my own estimation, anyway) anti-spam system that includes rate limiting and a user opt-in bypass.

# How To Run It

Like this:

```sh
ruby 4pleroma board_1.json board_2.json
```

This will start up a separate instance of the bot, using two threads each. Two for `board_1.json` and two for `board_2.json`.

# Editing Settings JSON Files

The JSON file in question has a series of fields, some of which you may edit, and some which you should not. Here are the fields you should edit:

* `name` -- the display name of the board, like "/tg/," "/k/," and so on. Can also be a longer form like "Traditional Games," depending on user preference
* `catalog_url` -- the URL of the catalog to be viewed. Example: `https://a.4cdn.org/tg/catalog.json`
* `thread_url` -- the thread URL with replacing values. Example: `https://a.4cdn.org/tg/thread/%%NUMBER%%.json`, where `%%NUMBER%%` is the thread number
* `image_url` -- the image URL with replacing values. Example: `https://i.4cdn.org/wg/%%TIM%%%%EXT%%`, where `%%TIM%%` is the remote filename of the image and `%%EXT%%` is the file extension on it.
* `janny_lag` -- how long jannies have to remove images for rules violations or illegal content (a human safeguard)
* `instance` -- the domain name of the Pleroma instance you're uploading to
* `content_prepend` -- a string to prepend to the status body of all images uploaded
* `content_append` -- a string to append to the status body of all images uploaded
* `bearer_token` -- the bearer token that both identifies and authenticates the bot account
* `badwords` -- an array of bad words. Threads using these words at all will not be examined for new things to add to the queue
* `badregex` -- like `badwords`, except these are regular expressions (stored as strings to conform to JSON's standard and then converted to regular expressions in Ruby) which exclude all threads that match

There are some that the bot maintains and you should probably leave alone. They are:
* `threads_touched` -- a list of threads that have been "touched" (accessed) and when they were most recently accessed
* `old_threads` -- information about threads that are already accessed, which gets purged as threads die
* `based_cringe` -- information about how based or cringe a thread is, where if cringe > based, no more images will be added to the queue for consideration
* `last_notification_id` -- the last notification from Pleroma, used for tracking reblogs (thus increasing a thread's based rating)