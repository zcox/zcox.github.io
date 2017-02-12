---
title: Repartition Topics in Kafka Streams
subtitle: Aggregations must consume topics keyed by the proper attribute for correct results
---

Imagine we have our web servers generate pageview events and send them to a Kafka topic for processing by other systems. Each pageview event consists of the following attributes:

- `eventId`: a string that uniquely identifies each event, e.g. a random UUID
- `timestamp`: the time at which the page was viewed, could be a [Unix timestamp](https://en.wikipedia.org/wiki/Unix_time), or an [ISO-8601 string](https://en.wikipedia.org/wiki/ISO_8601#Combined_date_and_time_representations)
- `url`: the URL of the page that was viewed

We decide to build a system to count the number of pageviews for each URL. We'll use [Kafka Streams](http://docs.confluent.io/current/streams/index.html) to compute the counts, store them in local state, and output the counts to another topic. An example of such a system can be found [in this project](https://github.com/zcox/kafka-streams-repartition-example).

# Starting Out: One Partition

Initially, our site doesn't have much traffic, so we use one partition of the events topic, and one instance of our application.

![](/img/repartition-topic/1.png)

The web servers send the pageview events to the Kafka topic in messages with the `eventId` as the message key, and all attributes in the message value. All pageview events are received by the single app instance, counts are computed per `url` and sent to the output topic in messages with `url` as the key and count as the value.

Let's imagine that these pageview events have been sent to the pageviews topic:

```
pv1|pv1,2017-02-12T16:41:25+00:00,https://site.com/page1
pv2|pv2,2017-02-12T16:41:26+00:00,https://site.com/page1
```

In this format, each message is on a separate line, and `|` separates the message key and value. The first pageview has `eventId=pv1`, `timestamp=2017-02-12T16:41:25+00:00`, and `url=https://site.com/page1`.

The single app instance ends up with this state:

url | count
--- | ---
https://site.com/page1 | 2

And the following message is sent to the output topic, with `url` as key and count as value. Everything is working correctly.

```
https://site.com/page1|2
```

# Scaling Out: Two Partitions

Our web site traffic grows over time, and now we need to scale out. We increase the pageview topic to two partitions, and also run two instances of our app. Each app instance consumes from a single topic partition. 

![](/img/repartition-topic/2.png)

Because the pageview topic messages are keyed by `eventId`, events with the same `url` can be sent to either partition. Let's assume the first event goes through partition 1 to app instance 1, while the second event goes through partition 2 to app instance 2. App instance 1's state looks like this:

url | count
--- | ---
https://site.com/page1 | 1

App instance 2's state looks the same:

url | count
--- | ---
https://site.com/page1 | 1

Each app instance sends an updated count message to the output topic:

```
https://site.com/page1|1
https://site.com/page1|1
```

But these are incorrect counts! Any consumer of this topic would think `https://site.com/page1` had only been viewed one time.

# Repartition Topics

To fix this, we need a new pageview topic with messages that use the `url` as the key (instead of `eventId`), so that pageviews with the same `url` are routed to the same partition, and the app needs to consume this new topic. Let's call this a _"repartition topic"_ because it's sending messages from the first topic to different partitions, based on a different message key, i.e. _repartitioning_ the messages. 

![](/img/repartition-topic/3.png)

Let's assume all messages with url `https://site.com/page1` get sent to repartition topic partition 1. Then app instance 1 receives both of the pageview events, updates its state correctly, and correctly sends this message to the output topic:

```
https://site.com/page1|2
```

So the output topic gets the correct counts again, but it looks like now we have to build a separate component to perform the repartioning. What a pain!

# Automatic Repartition Topics

Fortunately, Kafka Streams ([as of version 0.10.1.0](https://issues.apache.org/jira/browse/KAFKA-3561)) can automatically do this repartitioning for us, with no extra work on our part. Let's take a look at our application code:

```scala
val builder = new KStreamBuilder
builder
  .stream(pageviewsInputTopic)
  .selectKey((key: String, value: String) => PageviewFormat.fromMessageValue(value).url)
  .groupByKey()
  .count(pageviewCountsByUrlState)
  .to(Serdes.String(), Serdes.Long(), pageviewCountsByUrlOutputTopic)
```

The stream created from the input topic is keyed by the pageview's `eventId`, however we know we want to count pageviews by `url`. So we use the `selectKey` method to extract the pageview's `url`, and use that as the new message key. The `groupByKey` and `count` methods then correctly count pageviews by url. But where is the repartition topic?

If we run this program and list the topics, we find that there is one named `pageview-analytics-pageview-counts-by-url-repartition`. The messages in this topic are properly keyed by `url`:

```
https://site.com/page1|pv1,2017-02-12T16:41:25+00:00,https://site.com/page1
https://site.com/page1|pv2,2017-02-12T16:41:26+00:00,https://site.com/page1
```

It turns out that [internally](https://github.com/apache/kafka/blob/trunk/streams/src/main/java/org/apache/kafka/streams/kstream/internals/KStreamImpl.java), the `selectKey` method records the fact that a repartition topic will be required for certain other operations, such as counting by key, to work correctly. Kafka Streams automatically creates the repartition topic, writes messages through it with the new key, and then consumes from it in subsequent operations. 

![](/img/repartition-topic/4.png)

Note in this diagram that each app instance outputs to both repartition topic partitions, since it can re-key pageviews with any `url`. However, each app instance only consumes from a single repartition topic partition.

Kafka Streams creates a repartition topic as needed after any operation that changes the message key: 

- `selectKey`
- `map` (but not `mapValues`)
- `flatMap` (but not `flatMapValues`)
- `transform` (but not `transformValues`)

Note that if you're transforming a stream, but not changing the key (and thus do not need a repartition topic), then you should use one of the operations that does not create a repartition topic. For example, in this case use `mapValues` instead of the more general `map`.

One observation at this point is that if the original pageviews topic was already keyed by `url` (instead of `eventId`), this repartition topic would be unnecessary. This is definitely true. I think in a lot of cases, a best practice might be to key event topics like this by an event attribute most-likely to be grouped/aggregated on by other systems, instead of the `eventId`. This will likely minimize repartition topics. However, as soon as you need to group-by or aggregate on some other attribute, you will need a repartition topic keyed by that attribute. For example, if we also included `userId` in the pageview events and also wanted to count pageviews by `userId`, we'd need a repartition topic keyed by `userId`. So you may not be able to eliminate repartition topics entirely.

Another point of consideration is increasing partition counts. If our system has been running with two partitions for awhile, can we increase to three partitions? Since (by default) messages are routed to a partition using `hash(key) % partitionCount`, changing the number of partitions can change the partition that keys are assigned to, and they could end up in a different app instance without the correct state. How to properly increase partition count in a stateful stream processing system is a topic for another blog post, but just be aware of the consequences.

# Summary

In this post, we've seen that when a stateful stream processing system needs to aggregate events by a specific attribute, they must consume from a topic that is keyed by that attribute. It could be very easy for a human programmer to forget this fact, so Kafka Streams creates and uses _repartition topics_ automatically, when needed. This ensures correct results are computed. Pretty awesome!
