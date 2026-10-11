# SnapShare Scaling Plan

SnapShare is a photo-sharing app. Users upload photos and scroll a feed of photos from the people they follow. This plan works out how big the system is and how I would build it so it keeps working as it grows.

---

## 1. Assumptions

These are the starting facts I was given, plus the extra assumptions I made so the maths is clear.

**Given:**

- 10,000,000 registered users
- 10% of them are active each day
- Each active user uploads 1 photo per day
- Each active user views 50 feed pages per day
- An average photo is 2 MB
- Each photo also gets a thumbnail of 50 KB

**My extra assumptions:**

- 1 day = 86,400 seconds, and 1 year = 365 days
- Peak traffic is 5 times the average (as the task says)
- 1 TB = 1,000,000 MB (I used decimal units to keep the numbers simple)
- One "feed view" means one request for one page of the feed
- Storage only counts the photo files (the original and the thumbnail). It does not count database rows, backups or the extra copies a storage service keeps for safety, so the real number would be higher
- The number of users stays the same for the whole year (no growth), so the yearly figure is a starting point

**Daily active users (DAU):**

```
DAU = 10,000,000 x 10% = 1,000,000 active users per day
```

---

## 2. Estimates

| What | Working | Result |
|---|---|---|
| Uploads per day | 1,000,000 users x 1 photo | 1,000,000 |
| Uploads per second (average) | 1,000,000 / 86,400 | about 11.6 per second |
| Uploads per second (peak) | 11.6 x 5 | about 58 per second |
| Feed views per day | 1,000,000 users x 50 | 50,000,000 |
| Feed views per second (average) | 50,000,000 / 86,400 | about 579 per second |
| Feed views per second (peak) | 578.7 x 5 | about 2,894 per second |
| Storage per day | 1,000,000 x (2 MB + 0.05 MB) | 2.05 TB |
| Storage per year | 2.05 TB x 365 | about 748 TB (roughly 0.75 PB) |

**Storage per year, split up:**

- Original photos: 1,000,000 x 2 MB x 365 = 730 TB
- Thumbnails: 1,000,000 x 50 KB x 365 = 18.25 TB
- Total: 730 + 18.25 = 748.25 TB

The thumbnails only add about 2.5% extra storage.

**Extra number I worked out (upload bandwidth):**

- Average: 11.6 uploads per second x 2 MB = about 23 MB per second
- Peak: 58 uploads per second x 2 MB = about 116 MB per second (roughly 0.93 Gbit per second)

---

## 3. Read-heavy or write-heavy?

SnapShare is **read-heavy**.

Every active user views 50 feed pages for every 1 photo they upload, so reads outnumber writes by about 50 to 1 (579 feed views per second compared with 11.6 uploads per second on average). It is even more lopsided than that, because each feed page shows several photos, so the number of image downloads is higher than the number of feed views.

**What this means for the design:**

- Most of the effort should go into making reads fast and cheap: a cache, a read replica, and a CDN for the photo files.
- The feed should show the small 50 KB thumbnails, not the 2 MB originals. That is 40 times less data for every photo on the screen.
- Reads can be scaled by adding more copies (more app servers, more replicas, more cache), so the design should make that easy.
- Writes are rare, but each upload is big (2 MB), so the upload path still needs care. The photo file must go to storage built for large files, and slow work (making thumbnails) should happen in the background.
- The one thing that grows forever is storage (about 748 TB a year), so the storage needs to be cheap and able to grow without limit.

---

## 4. Why photos should not be stored inside the database

A database is good at small, structured rows that we search and update (users, follows, captions). Photos are big binary files, and putting them in the database causes problems:

- **Size:** 748 TB a year is far too much for a database server. Database disks are expensive and hard to grow.
- **Speed:** sending 2 MB files through the database uses up its connections and memory, which slows down the normal queries that the feed depends on.
- **Copying:** the read replica copies everything in the primary database. If photos were inside, every replica and every backup would need a full copy of every photo.
- **No CDN:** a CDN cannot pull files straight out of a database. It needs a simple file address (a URL).
- **Cost:** storing files in object storage is much cheaper per TB than storing them in a database.

**Where they go instead:** photos and thumbnails go in **object storage** (a service made for storing huge numbers of files, such as Amazon S3). The database only keeps a small row about each photo: the photo ID, the user ID, the file key (the name of the file in object storage), the thumbnail key, the caption, the time, and a status. The CDN then serves the files using those keys.

---

## 5. Architecture diagram

```
          +-----------------------------------------------------------+
          |                Users (phones and browsers)                |
          +-----------------------------------------------------------+
                        | API requests                          ^ photos and
                        | (feed, upload)                        | thumbnails
                        v                                       |
                +---------------+                           +-------+
                | Load balancer |                           |  CDN  |
                +---------------+                           +-------+
                        |                                       ^
                        v                                       |
              +-------------------+   CDN fetches the file only |
              |    App servers    |             on a cache miss |
              |   (many copies)   |                             |
              +-------------------+                             |
                        |                                       |
         +--------------+----------+------+------------+        |
         v              v          |      v            v        |
  +------------+ +------------+    |  +-------+   +------------------+
  |   Cache    | |  Database  |    |  | Queue |   |  Object storage  |
  |(e.g. Redis)| | (primary)  |    |  +-------+   |  (photo files)   |
  +------------+ +------------+    |      |       +------------------+
    copies every change |          |      v               ^
                        v          |  +--------+          | read original,
                +--------------+   |  | Worker |----------+ save thumbnail
                | Read replica |<--+  +--------+
                +--------------+
```

**How to read the arrows:**

- Users send API requests (load the feed, upload a photo) to the load balancer, which passes them to one of the app servers.
- The app servers check the cache first. Writes go to the primary database. Feed reads go to the read replica. The primary database keeps the replica up to date by copying every change to it.
- When a photo is uploaded, the app server saves the file in object storage and puts a "make a thumbnail" job on the queue.
- The worker takes jobs from the queue, reads the original photo from object storage, saves the thumbnail back into object storage, and then marks the photo as ready in the database.
- Users download photos and thumbnails through the CDN. The CDN only goes to object storage when it does not already have a copy.

---

## 6. What each component does (one sentence each)

- **CDN:** it fixes slow downloads for users who are far from our servers, and takes most of the photo traffic off our storage, by keeping copies of popular photos and thumbnails on servers close to the users.
- **Load balancer:** it fixes one server getting overloaded (or one broken server taking the app down) by spreading requests across many app servers and skipping any that are not working.
- **App servers:** they run the SnapShare code (login, feed, upload) and, because they keep no data of their own, we can handle more traffic just by adding more identical copies.
- **Cache:** it fixes the database being asked the same question again and again (like building a popular feed) by keeping recent answers in fast memory.
- **Database (primary):** it fixes where to keep the important structured data (users, follows, photo records) so it stays correct, by sending every write through one trusted place.
- **Read replica:** it fixes the heavy read load (about 2,894 feed views per second at peak) overwhelming the primary database by answering reads from an up-to-date copy.
- **Object storage:** it fixes where to keep a huge and growing number of big files (about 748 TB a year) cheaply and safely, which a database cannot do well.
- **Queue:** it fixes the upload request having to wait for slow work, because the app server can drop a "make a thumbnail" job on the queue and reply straight away, and the job waits safely if the workers are busy.
- **Worker:** it fixes thumbnail creation slowing down the website by doing that job in the background, and we can add more workers if the queue gets long.

---

## 7. Upload flow, step by step

1. The user picks a photo, adds a caption and taps Upload. The app sends the photo to SnapShare, along with the user's login token.
2. The request reaches the **load balancer**, which sends it to a healthy **app server**.
3. The app server checks the login token and checks the photo (allowed file type and size limit).
4. The app server saves the original photo in **object storage** under a unique key, for example `photos/<user_id>/<photo_id>.jpg`.
5. The app server adds a row for the photo to the **primary database** (photo ID, user ID, file key, caption, time) with the status `processing`. It does this after the file is saved, so no row ever points to a missing file.
6. The app server puts a message on the **queue**, for example `{photo_id, file_key}`.
7. The app server replies to the user straight away ("upload successful"). The user does not wait for the thumbnail.
8. A **worker** takes the message from the queue, reads the original from object storage, makes a 50 KB thumbnail (resize and compress), and saves it in object storage.
9. The worker updates the photo's row in the database: it adds the thumbnail key and changes the status to `ready`. If the job fails, it goes back on the queue and is tried again. After a few failed tries it is set aside so someone can look at it.
10. The change is copied to the **read replica**. The next time the user's followers load their feed (once the cached copy has expired), the new photo appears. The **CDN** gets the thumbnail from object storage the first time someone asks for it, and keeps a copy for everyone after that.

---

## 8. Trade-offs

**1. Cache: faster reads, but the data can be out of date.**
A cache cuts the load on the database a lot, which matters because SnapShare is read-heavy. The cost is that cached feeds can be a little old, so a new photo may take a short while to show up (until the cached copy expires or is refreshed). Deciding when to throw away cached data is also hard to get right, and the cache is one more thing to run.

**2. Read replica: handles more reads, but copies are slightly behind.**
The replica takes read traffic off the primary database, but it learns about changes a moment after the primary does (replication lag). A user could upload a photo and not see it straight away if their next request is answered by the replica. One fix is to read a user's own recent photos from the primary. It also costs extra money to run another database server.

**3. Queue and worker: fast uploads, but the thumbnail is not instant.**
Making thumbnails in the background keeps uploads quick and lets us handle spikes, because jobs wait in the queue. The cost is that for a short time the photo exists without a thumbnail (the app can show a placeholder). It also adds more parts to run and watch: retries, failed jobs, and what happens if the queue gets very long.

**4. Uploading through the app servers is simple, but it uses their bandwidth.**
In my flow the photo passes through an app server before reaching object storage. This is easy to build and lets the server check the photo first. But at peak that is about 116 MB per second of upload traffic going through the app servers. A more advanced option is to let the user's phone upload straight to object storage using a temporary upload link (a pre-signed URL). That takes the load off the app servers but makes the flow more complicated.

**5. Thumbnails: a little extra storage for much faster feeds.**
Storing a 50 KB thumbnail for every photo adds only about 18 TB a year (around 2.5% more storage). In return the feed loads 40 times less data for each photo, so it is much faster and the CDN bill is lower. The cost is the extra storage and the worker that creates them.
