# SnapShare Scaling Plan

SnapShare is a photo-sharing app. Users upload photos and scroll a feed of photos from people they follow. This plan works out how big the system is, then shows how I would build it so it keeps working as it grows.

---

## 1. Assumptions

**Given:** 10,000,000 registered users; 10% active each day; each active user uploads 1 photo and views 50 feed pages per day; average photo 2 MB; each photo also gets a 50 KB thumbnail.

**My extra assumptions:**

- 1 day = 86,400 seconds; 1 year = 365 days; decimal units (1 TB = 1,000,000 MB).
- Peak traffic = 5 x average.
- One feed view = one request for one page of the feed. A feed page shows **10 thumbnails**.
- Storage counts only photo files (original + thumbnail), not database rows, backups or storage copies, so the real number is higher.
- No user growth during the year, so the yearly figure is a starting point.
- Sizing guesses: one app server handles about 500 requests/s; one worker makes a thumbnail in about 0.5 s; the CDN serves 90% of image requests without asking storage; an average user follows 200 people.

**Daily active users (DAU):**

```
DAU = 10,000,000 x 10% = 1,000,000 active users per day
```

---

## 2. Estimates

| What | Working | Result |
|---|---|---|
| Uploads per day | 1,000,000 x 1 | 1,000,000 |
| Uploads per second (average) | 1,000,000 / 86,400 | about 11.6 /s |
| Uploads per second (peak) | 11.6 x 5 | about 58 /s |
| Feed views per day | 1,000,000 x 50 | 50,000,000 |
| Feed views per second (average) | 50,000,000 / 86,400 | about 579 /s |
| Feed views per second (peak) | 579 x 5 | about 2,894 /s |
| Storage per day | 1,000,000 x (2 MB + 0.05 MB) | 2.05 TB |
| **Storage per year** | 2.05 TB x 365 | **about 748 TB (0.75 PB)** |

Storage split: originals 1,000,000 x 2 MB x 365 = 730 TB; thumbnails 1,000,000 x 50 KB x 365 = 18.25 TB. Thumbnails add only about 2.5%. Storage grows by about 62 TB every month.

### Bandwidth (network can be a bottleneck as well as disk)

| What | Working | Result |
|---|---|---|
| Upload (ingress), average | 11.6 x 2 MB | about 23 MB/s (0.19 Gbps) |
| Upload (ingress), peak | 58 x 2 MB | about 116 MB/s (0.93 Gbps) |
| Thumbnail requests, average / peak | 579 x 10 / 2,894 x 10 | about 5,800 / 28,900 per second |
| Feed download (egress), peak, thumbnails | 2,894 x 10 x 50 KB | about 1.45 GB/s (**11.6 Gbps**) |
| Feed download (egress), peak, originals | 2,894 x 10 x 2 MB | about 58 GB/s (**463 Gbps**) |
| Traffic reaching storage after CDN (10% miss) | 11.6 Gbps x 10% | about 1.2 Gbps |

Sending 2 MB originals in the feed would need 40 times more bandwidth than thumbnails. Even with thumbnails, 11.6 Gbps is too much for our own servers, so the CDN must carry it.

---

## 3. Read-heavy or write-heavy?

SnapShare is **read-heavy**. Reads outnumber writes about 50 to 1 (579 feed views/s vs 11.6 uploads/s), and it is more lopsided than that because every feed page loads about 10 images.

**What this means for the design:**

- Spend the effort on fast, cheap reads: a CDN, a cache and read replicas.
- Show 50 KB thumbnails in the feed, and load the 2 MB original only when a user opens a photo.
- Reads scale by adding copies (app servers, replicas, cache), so keep every layer easy to copy.
- Writes are rare, so one primary database is enough. But each upload is big (2 MB), so files go to object storage and slow work (thumbnails) runs in the background.
- Storage is the one thing that grows forever, so it must be cheap and able to grow without limit.

---

## 4. Why photos should not be stored inside the database

- **Size:** 748 TB a year is far too much for a database server, and database disks are expensive and hard to grow.
- **Memory:** 2 MB files fill the database's memory and push out the small, hot rows (users, follows, captions) that the feed needs.
- **Replication:** the read replica copies everything on the primary, so every replica and backup would need a full copy of every photo, and replication would fall behind.
- **No CDN:** a CDN cannot pull files out of database rows; it needs a simple URL.
- **Cost:** object storage is much cheaper per TB.

**Where they go instead:** **object storage** (for example Amazon S3). The database keeps only a small row per photo: photo ID, user ID, file key, thumbnail key, caption, time and status (about 300 bytes).

---

## 5. Sizing each layer

| Layer | Calculation | Plan |
|---|---|---|
| App servers | peak 2,894 + 58 = about 2,950 req/s; 2,950 / 500 = 6 | **12 servers** (double for headroom and failures), in 3 zones |
| Cache | feed of about 50 photo IDs + details = 5 KB per user x 1M DAU = 5 GB | **2 Redis nodes** (primary + replica), about 16 GB each |
| Database reads | feed reads 2,894/s x 10% cache miss | about 290 reads/s, easy for **2 read replicas** |
| Database size | photo rows 300 B x 1M x 365 = 110 GB/year; follows 10M x 200 x 16 B = 32 GB | under 1 TB, so **one primary** is enough for now |
| Database writes | 58 uploads/s at peak, plus follows and likes | tiny, one primary copes |
| Queue | 58 jobs/s at peak | one managed queue |
| Workers | 58 jobs/s x 0.5 s = 29 busy workers | **40 workers** so a backlog can drain |
| Object storage | 62 TB per month, grows forever | managed service with built-in copies |

---

## 6. Architecture diagram

          Users ------------------> CDN --(miss)--> Object storage
  |                                         ^        ^
  v                                         |(1)     |(4)
Load balancer                               |        |
  |                                         |        |
  v                                         |        |
App servers --(1) save original ------------+        |
  |   |                                             |
  |   +--(3) job--> Queue --> Workers --(4) thumb --+
  |                              |
  |--(2) photo row --> DB primary <-- (5) mark ready
  |                       | copies changes
  +-- feed reads --> Cache --miss--> Read replica


A design trade-off is a choice between design options where improving one quality costs another.

Trade-off 1: Make thumbnails in the background (queue + worker) vs during the upload.

	•	Chosen: the app server saves the photo, puts a job on the queue and replies at once; a worker makes the thumbnail.
	•	Alternative: make the thumbnail inside the upload request, with no queue or worker.
	•	Gain: fast upload response, and spikes (58 uploads/s at peak) wait in the queue instead of slowing the site.
	•	Give up: simplicity and instant thumbnails. The photo briefly has a placeholder, and we must run and monitor a queue, retries and failed jobs.

Trade-off 2: Cache feeds in Redis vs always reading from the database.

	•	Chosen: the app server reads feeds from the cache and only asks a read replica on a miss.
	•	Alternative: query the database for every feed view.
	•	Gain: database reads fall from about 2,894/s to about 290/s, so 2 read replicas are enough.
	•	Give up: freshness and simplicity. A feed can be slightly old, cache clearing is hard to get right, and the cache is one more system to run (so it gets its own replica).
---

## 7. What each component does (one sentence each)

- **CDN:** it fixes slow downloads for faraway users and keeps most of the 11.6 Gbps of photo traffic off our servers, by keeping copies of popular photos and thumbnails close to users.
- **Load balancer:** it fixes one server being overloaded (or one broken server taking the app down) by spreading requests across app servers and skipping any that are not working.
- **App servers:** they run the SnapShare code (login, feed, upload) and, since they keep no data of their own, we handle more traffic just by adding identical copies.
- **Cache:** it fixes the database being asked the same question again and again by keeping ready-made feeds in fast memory.
- **Database (primary):** it fixes where to keep important structured data (users, follows, photo records) so it stays correct, by sending every write through one trusted place.
- **Read replica:** it fixes heavy read load overwhelming the primary by answering reads from an up-to-date copy, and it can take over if the primary fails.
- **Object storage:** it fixes where to keep a huge, growing number of big files (748 TB a year) cheaply and safely, which a database cannot do well.
- **Queue:** it fixes the upload request waiting for slow work, because the app server drops a job on the queue and replies at once, and jobs wait safely if workers are busy.
- **Worker:** it fixes thumbnail creation slowing down the website by doing it in the background, and we add more workers if the queue grows.

---

## 8. Upload flow, step by step

1. The user picks a photo, adds a caption and taps Upload. The app sends it with the user's login token.
2. The **load balancer** sends the request to a healthy **app server**.
3. The app server checks the token and the photo (allowed file type, size limit, really an image).
4. **(1)** The app server saves the original in **object storage** under a unique key, for example `photos/<user_id>/<photo_id>.jpg`.
5. **(2)** It adds a row to the **primary database** (photo ID, user ID, file key, caption, time) with status `processing`. This happens after the file is saved, so no row ever points to a missing file.
6. **(3)** It puts a message on the **queue**, for example `{photo_id, file_key}`.
7. It replies "upload successful" straight away. The user does not wait for the thumbnail.
8. **(4)** A **worker** takes the message, reads the original, makes a 50 KB thumbnail (resize and compress) and saves it in object storage.
9. **(5)** The worker updates the photo row with the thumbnail key and status `ready`. If the job fails it goes back on the queue and is retried; after a few failures it moves to a "failed jobs" list for someone to check. Retrying is safe because making the same thumbnail twice gives the same result.
10. The worker then adds the photo ID to the cached feeds of the uploader's followers, so it shows up in their feeds (see trade-off 1).
11. The change is copied to the read replicas. The **CDN** fetches the thumbnail from object storage the first time someone asks for it and serves everyone after that from its own copy.

**Feed flow:** the app server reads the user's feed from the cache; on a miss it asks a read replica, rebuilds the feed and stores it in the cache. The response contains thumbnail URLs, which the phone loads from the CDN.

---

## 9. Trade-offs

**1. Building feeds: push or pull.**
Pushing a new photo into every follower's cached feed (fan-out on write) makes reads very fast, which suits a 50-to-1 read-heavy app. At 200 followers that is 58 x 200 = about 11,600 cache writes per second at peak, which is fine. The cost is that a user with millions of followers would cause millions of writes for one photo. For those few users I would not push; their photos are pulled and merged into the feed when it is read.

**2. Cache: faster reads, but data can be out of date.**
A cache removes most database load, but a cached feed can be a little old and deciding when to clear it is hard. The cache is also one more thing to run, so if it fails the database must be able to cope for a short time (about 2,900 reads/s without the cache is too much for the replicas, so we rely on the cache having a replica too).

**3. Read replica: more reads, but copies lag behind.**
Replicas take read traffic from the primary, but they learn about changes a moment later. A user might upload a photo and not see it at once. Fix: read a user's own recent photos from the primary. Replicas also cost extra money.

**4. Queue and worker: fast uploads, but the thumbnail is not instant.**
Background work keeps uploads quick and absorbs spikes. For a short time the photo has no thumbnail (the app shows a placeholder), and we must run and watch retries, failed jobs and queue length.

**5. Upload through app servers: simple, but heavy.**
Sending the photo through the app server makes validation easy, but peak upload traffic (about 116 MB/s, nearly 1 Gbps) passes through our servers. A better version for later is a **pre-signed URL**: the app server gives the phone a temporary link and the phone uploads straight to object storage, then tells us it is done. That removes the load but makes the flow more complex.

**6. Thumbnails: a little storage for much faster feeds.**
They add about 18 TB a year (2.5%) and need a worker, but cut feed bandwidth from about 463 Gbps to 11.6 Gbps at peak.

---

## 10. Single points of failure and failures

| If this fails | What happens | How we cope |
|---|---|---|
| App server | requests to it fail | load balancer stops using it; 12 servers across 3 zones |
| Load balancer | no traffic gets in | run two (active/standby) |
| Cache | feeds slower | Redis replica takes over; app falls back to replicas |
| DB primary | no new uploads or posts | promote a read replica; reads keep working meanwhile |
| Worker | thumbnails delayed | jobs stay on the queue; other workers continue |
| Queue | jobs can be lost | use a durable managed queue with retries |
| Object storage | files unavailable | managed service stores copies in several places |
| CDN | slower, more load on storage | CDN has many edge servers; storage can serve directly as backup |

**What I would monitor:** upload and feed latency, error rate, cache hit rate (aim for 90%+), CDN hit rate, replication lag, queue length and age of oldest job, storage used.

---

## 11. If traffic grows 10 times

Add app servers, replicas, cache nodes and workers first (they scale by copying). Then shard the database by user ID (the primary would pass about 1 TB a year and about 600 writes/s at peak), move to pre-signed uploads, and add storage tiers (move old photos to cheaper "cold" storage).

