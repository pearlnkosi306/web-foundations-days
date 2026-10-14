# SnapShare Scaling Plan (V2)

SnapShare lets users upload photos and scroll a feed of photos from people they follow.

## 1. Assumptions and estimates

**Given:** 10,000,000 registered users; 10% active daily; each active user uploads 1 photo and views 50 feed pages per day; photo = 2 MB; thumbnail = 50 KB.
**My assumptions:** 86,400 s/day; 365 days/year; peak = 5x average; 1 TB = 1,000,000 MB; 1 feed page shows 10 thumbnails.

**Daily active users (DAU) = 10,000,000 x 10% = 1,000,000**

| What | Working | Result |
|---|---|---|
| Uploads/s (average) | 1,000,000 / 86,400 | about 12 /s |
| Uploads/s (peak) | 12 x 5 | about 58 /s |
| Feed views/s (average) | 50,000,000 / 86,400 | about 579 /s |
| Feed views/s (peak) | 579 x 5 | about 2,894 /s |
| Storage per year | originals 730 TB + thumbnails 18 TB | **about 748 TB** |
| Upload bandwidth (peak) | 58 x 2 MB | about 116 MB/s (1 Gbps) |

## 2. Read-heavy or write-heavy?

**Read-heavy:** 579 feed views/s against 12 uploads/s is about 50 to 1. So we make reads fast and cheap (CDN, cache, read replica, thumbnails) and move slow write work (thumbnails) to the background.

## 3. Why photos stay out of the database

- 2 MB files fill the database memory and push out the small, hot rows.
- Every photo would be copied to each read replica and backup, slowing replication.
- A CDN cannot cache a file that lives inside a database row.
- 748 TB a year is far cheaper in object storage.

**Instead:** photos and thumbnails go in **object storage** (e.g. S3). The database keeps only the file key, owner, caption, time and status.

## 4. Architecture diagram

```text
+------------------------------------------+
|       Users (phones and browsers)        |
+------------------------------------------+
    |  API calls                        ^ images
    v                                   |
+---------------+                   +-------+
| Load balancer | <- spreads load   |  CDN  |  <- images near users
+---------------+                   +-------+
    |                                   ^
    v                                   | fetch on miss
+---------------+   save original   +----------------+
|  App servers  |------------------>| Object storage |  <- photo files
| (many copies) |                   +----------------+
+-------|-------+                             ^
  +-----+-----------+------------+            | save thumbnail
  v                 v            v            | read original
+----------+  +------------+ +--------+    +------------+
|  Cache   |  | DB primary | | Queue  |--->|   Worker   |  <- background job
| (Redis)  |  |  (writes)  | | (jobs) |    |(thumbnails)|
+----------+  +------------+ +--------+    +------------+
      | miss        |
      |             v copies every change
      |     +--------------+
      +---->| Read replica |  <- answers feed reads
            +--------------+
```

### Two design trade-offs for this architecture

A design trade-off is a choice between design options where improving one quality costs another.

**Trade-off 1: Make thumbnails in the background (queue + worker) vs during the upload.**
- *Chosen:* the app server saves the photo, puts a job on the queue and replies at once; a worker makes the thumbnail.
- *Alternative:* make the thumbnail inside the upload request, with no queue or worker.
- *Gain:* fast upload response, and spikes (58 uploads/s at peak) wait in the queue instead of slowing the site.
- *Give up:* simplicity and instant thumbnails. The photo briefly has a placeholder, and we must run and monitor a queue, retries and failed jobs.

**Trade-off 2: Cache feeds in Redis vs always reading from the database.**
- *Chosen:* the app server reads feeds from the cache and only asks a read replica on a miss.
- *Alternative:* query the database for every feed view.
- *Gain:* database reads fall from about 2,894/s to about 290/s, so 2 read replicas are enough.
- *Give up:* freshness and simplicity. A feed can be slightly old, cache clearing is hard to get right, and the cache is one more system to run (so it gets its own replica).

## 5. Components (one sentence each)

- **CDN:** fixes slow downloads for faraway users and keeps most photo traffic off our servers by storing copies near users.
- **Load balancer:** fixes one server being overloaded by spreading requests across app servers and skipping broken ones.
- **App servers:** run the login, feed and upload code, and being stateless we add more copies to handle more traffic.
- **Cache:** fixes the database answering the same feed question again and again by keeping recent feeds in fast memory.
- **Database (primary):** keeps users, follows and photo records correct by sending every write through one trusted place.
- **Read replica:** fixes heavy read load on the primary by answering reads from an up-to-date copy.
- **Object storage:** keeps the huge, growing pile of photo files cheaply and safely, which a database cannot do well.
- **Queue:** fixes uploads waiting for slow work by holding "make a thumbnail" jobs safely until a worker is free.
- **Worker:** makes thumbnails in the background so the website stays fast, and we add more workers if the queue grows.

## 6. Upload flow, step by step

1. The user taps Upload; the request goes to the **load balancer**, then a healthy **app server**.
2. The app server checks the login token, file type and size limit.
3. It saves the 2 MB original in **object storage**.
4. It adds a row to the **primary database** with status `processing`.
5. It puts a job `{photo_id, file_key}` on the **queue**.
6. It replies "upload successful" at once; the user does not wait for the thumbnail.
7. A **worker** takes the job, reads the original, makes a 50 KB thumbnail and saves it to object storage.
8. The worker marks the row `ready` with the thumbnail key. If it fails, the job is retried, then set aside after a few tries.
9. The change copies to the read replica; followers' feeds show the photo, and the **CDN** serves the thumbnail.

## 7. Capacity at a glance

| Layer | Calculation | Plan |
|---|---|---|
| App servers | 2,950 req/s at peak / 500 per server = 6 | 12 servers in 3 zones |
| Cache | 5 KB per user x 1M DAU = 5 GB | 2 Redis nodes (primary + replica) |
| Database | about 290 reads/s after cache; 58 writes/s | 1 primary + 2 read replicas |
| Workers | 58 jobs/s x 0.5 s = 29 busy | 40 workers |
| Object storage | 62 TB per month | managed, grows without limit |
