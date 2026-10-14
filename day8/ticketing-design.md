# TicketHub: System Design

TicketHub is a website that sells tickets for concerts and events. This document follows the six-part framework from Part 1 (requirements, estimates, API, data model, architecture, trade-offs). Section 5 is a dedicated section on how the design stops two people buying the same seat.

---

## 1. Requirements

### Functional requirements (what the system must do)

1. Browse and search events by name, city and date.
2. Open an event and see a seat map showing which seats are available, held or sold.
3. Register and log in.
4. Hold up to 4 seats for 5 minutes while paying.
5. Pay for the held seats and get a confirmation.
6. View my tickets (with a QR code) after paying.
7. Release a hold I no longer want.

Out of scope: refunds, resale between users, organiser tools for creating events, and drawing seat maps.

### Non-functional requirements (how well it must do it)

**Speed**
- On a normal day, 95% of browsing requests are answered in under 500 ms (server time).
- Holding seats gets an answer in under 1 second, even during a big sale.
- The seat map is never more than about 2 seconds out of date.

**Correctness (the most important one)**
- A seat is never sold to two people.
- No one is charged without getting a ticket, and no ticket exists without a payment.
- A paid order is never lost (it must survive a server crash).
- A hold that is not paid for expires by itself, so seats do not stay locked forever.

**Fairness**
- First come, first served. People who arrive before the sale opens are put in a random order, so a faster internet connection is not an advantage.
- Maximum 4 seats per order and per user for each event, plus rate limits per account and per IP address, to slow down bots and scalpers.
- People who miss out are told quickly ("sold out"), not left staring at a spinner.

**Availability and scale**
- Browsing stays up even if payment is slow.
- During a big sale the site shows a waiting room instead of crashing.
- It must handle roughly 575 times the normal load for short bursts (see section 2).

**Security**
- HTTPS everywhere, hashed passwords, and card details handled only by the payment provider (we never store card numbers).

---

## 2. Estimates

### Assumptions

- One page view is about one API request.
- On a normal day, the busiest hour has 3 times the average traffic.
- In the big sale, each buyer makes about 10 requests in 10 minutes (open the event, refresh the seat map a few times, about 3 hold attempts, pay).
- One database row is about 1 KB.

### Normal day

| Item | Calculation | Result |
|---|---|---|
| Page views per day | 50,000 visitors x 10 pages | 500,000 |
| Average requests per second | 500,000 / 86,400 s | about 5.8 per second |
| Busiest hour (3x average) | 5.8 x 3 | about 17 per second |
| Tickets sold per second | 5,000 / 86,400 s | about 0.06 per second (one sale every 17 seconds) |
| Reads to writes | 500,000 views : 5,000 purchases | 100 : 1, so read-heavy |
| Storage growth | 5,000 tickets x 365 days = 1.8 million rows x 1 KB | about 1.8 GB per year |

Visitors are 50,000 of 2 million registered users, so only 2.5% of users are active on a normal day. The data is small. A single database can hold it, so the challenge is traffic and correctness, not storage.

### Big sale (the first 10 minutes)

| Item | Calculation | Result |
|---|---|---|
| Buyers arriving per second | 200,000 / 600 s | about 333 per second |
| Average requests per second | 200,000 x 10 requests / 600 s | about 3,300 per second |
| Spike in the first 30 seconds (assume 3x) | 3,300 x 3 | about 10,000 per second |
| Seat-hold attempts per second | 200,000 x 3 attempts / 600 s | about 1,000 per second |
| Competition for seats | 200,000 people / 20,000 seats | 10 people per seat, so 90% (180,000 people) go home without a ticket |
| Sales per second if it takes the full 10 minutes | 20,000 / 600 s | about 33 per second (more if it sells out faster) |

### Comparison

| | Normal day | Big sale | Difference |
|---|---|---|---|
| Requests per second (average) | 5.8 | 3,300 | about 575 times more |
| Requests per second (spike) | 5.8 | 10,000 | about 1,700 times more |
| Tickets sold per second | 0.06 | 33 | about 575 times more |
| People in the window | 50,000 in a whole day | 200,000 in 10 minutes | 4 times a normal day's visitors in 10 minutes |

What this tells me:
- I must design for the peak, not the average. A server that is fine all year would fall over in the first minute.
- There are two different problems. The first is **read volume** (about 7 of every 10 requests are still reads, such as event pages and seat maps), which caching solves. The second is **write contention** (200,000 people fighting over 20,000 seats), which needs database transactions, constraints and a waiting room.
- On a normal day the site is read-heavy. In the big sale the hard part becomes correctness under pressure, because 20,000 tickets are sold in minutes (4 times a whole normal day's sales).

---

## 3. API

REST, JSON, over HTTPS. Logged-in routes need an `Authorization: Bearer <token>` header. During a hot sale, the hold and pay routes also need an `X-Queue-Token` header, which the waiting room gives to admitted users. Register and log in (`POST /users`, `POST /auth/login`) work as usual and are left out of the table to keep it focused.

| # | Method and path | Purpose | Success | Errors |
|---|---|---|---|---|
| 1 | `GET /events?q=&city=&date=&page=` | Browse and search events | 200 list of events | 400 bad filter |
| 2 | `GET /events/{eventId}` | Event details | 200 event | 404 not found |
| 3 | `GET /events/{eventId}/seats?section=` | View seats and their status | 200 list of seats (available, held, sold) | 404 not found |
| 4 | `POST /events/{eventId}/holds` | Hold seats for 5 minutes | 201 order with expiry time | 400 more than 4 seats, 401 not logged in, 403 no queue token, 409 seat taken, 429 too many requests |
| 5 | `DELETE /orders/{orderId}/hold` | Release a hold | 204 no content | 404 not found, 409 already paid |
| 6 | `POST /orders/{orderId}/payment` | Pay for held seats | 200 order paid with tickets | 402 payment failed, 410 hold expired, 409 already paid |
| 7 | `GET /me/tickets` | View my tickets | 200 list of tickets with QR codes | 401 not logged in |

The payment request carries an `Idempotency-Key` header so that a double-click or a retry never charges twice.

**Example: hold two seats**

```
POST /events/42/holds
{ "seatIds": [1101, 1102] }
```

Success (201):

```json
{
  "orderId": 9001,
  "eventId": 42,
  "seatIds": [1101, 1102],
  "totalCents": 24000,
  "expiresAt": "2026-12-01T10:05:00Z"
}
```

Someone else got a seat first (409):

```json
{
  "error": "SEAT_TAKEN",
  "message": "Seat 1102 was just taken. Please choose another seat.",
  "unavailableSeatIds": [1102]
}
```

**Example: pay**

```
POST /orders/9001/payment
Idempotency-Key: 6f1c...
{ "paymentToken": "tok_from_payment_provider" }
```

Success (200):

```json
{
  "orderId": 9001,
  "status": "paid",
  "tickets": [
    { "ticketId": 55001, "seatId": 1101, "qrCode": "..." },
    { "ticketId": 55002, "seatId": 1102, "qrCode": "..." }
  ]
}
```

---

## 4. Data model

Five tables. SQL is written in PostgreSQL style. The same ideas work in SQLite or MySQL.

### Relationships

- One **user** has many **orders** (users 1 : N orders).
- One **event** has many **seats** (events 1 : N seats) and many **orders** (events 1 : N orders).
- One **order** has many **tickets** (orders 1 : N tickets).
- One **seat** has at most one valid **ticket** (seats 1 : 0..1 tickets). This rule is enforced by the database, not just by the code.
- A seat that is held or sold points to the **order** that holds it.

### Tables

```sql
CREATE TABLE users (
  user_id        INTEGER PRIMARY KEY,
  email          TEXT NOT NULL UNIQUE,
  name           TEXT NOT NULL,
  password_hash  TEXT NOT NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE events (
  event_id    INTEGER PRIMARY KEY,
  title       TEXT NOT NULL,
  venue       TEXT NOT NULL,
  city        TEXT NOT NULL,
  starts_at   TIMESTAMP NOT NULL,
  on_sale_at  TIMESTAMP NOT NULL,
  status      TEXT NOT NULL DEFAULT 'scheduled'
              CHECK (status IN ('scheduled', 'on_sale', 'sold_out', 'cancelled'))
);

CREATE TABLE orders (
  order_id         INTEGER PRIMARY KEY,
  user_id          INTEGER NOT NULL REFERENCES users(user_id),
  event_id         INTEGER NOT NULL REFERENCES events(event_id),
  status           TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'paid', 'expired', 'cancelled')),
  total_cents      INTEGER NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
  hold_expires_at  TIMESTAMP NOT NULL,
  payment_ref      TEXT UNIQUE,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE seats (
  seat_id          INTEGER PRIMARY KEY,
  event_id         INTEGER NOT NULL REFERENCES events(event_id),
  section          TEXT NOT NULL,
  row_label        TEXT NOT NULL,
  seat_number      INTEGER NOT NULL,
  price_cents      INTEGER NOT NULL CHECK (price_cents > 0),
  status           TEXT NOT NULL DEFAULT 'available'
                   CHECK (status IN ('available', 'held', 'sold')),
  order_id         INTEGER REFERENCES orders(order_id),
  hold_expires_at  TIMESTAMP,
  UNIQUE (event_id, section, row_label, seat_number),
  CHECK (status = 'available' OR order_id IS NOT NULL)
);

CREATE TABLE tickets (
  ticket_id    INTEGER PRIMARY KEY,
  order_id     INTEGER NOT NULL REFERENCES orders(order_id),
  seat_id      INTEGER NOT NULL REFERENCES seats(seat_id),
  price_cents  INTEGER NOT NULL,
  qr_code      TEXT NOT NULL UNIQUE,
  status       TEXT NOT NULL DEFAULT 'valid' CHECK (status IN ('valid', 'cancelled'))
);

-- The safety net: a seat can have only ONE valid ticket, ever.
CREATE UNIQUE INDEX one_valid_ticket_per_seat
  ON tickets (seat_id) WHERE status = 'valid';
```

### Why these tables

- `seats` has one row for every seat of every event. The `status` column (available, held, sold) is the single source of truth for a seat.
- `orders` groups the seats one person is buying and holds the expiry time and the payment reference.
- `tickets` is the permanent record of what was bought (with the price paid at that moment and a QR code). It also gives me the unique-index safety net.
- `payment_ref` is `UNIQUE`, so the same payment cannot be used for two orders.

### Indexes

```sql
CREATE INDEX idx_seats_event_status ON seats (event_id, status);   -- draw the seat map fast
CREATE INDEX idx_orders_user ON orders (user_id);                  -- "my tickets"
CREATE INDEX idx_orders_pending_expiry ON orders (hold_expires_at)
  WHERE status = 'pending';                                        -- find expired holds fast
```

---

## 5. How TicketHub prevents two people buying the same seat

The danger is a race condition. Say Ana and Ben both click seat 1101 at the same moment. If the code first checks "is it free?" and then, as a separate step, marks it taken, both checks can say "yes, free" before either update happens. Both people would then think they got the seat. This is the "check, then act" mistake.

The fix is to do the check and the change **in one atomic step**, inside a transaction, and to back it up with constraints.

### Layer 1: one atomic conditional UPDATE

```sql
BEGIN;

-- Create the pending order (the hold lasts 5 minutes)
INSERT INTO orders (user_id, event_id, status, hold_expires_at)
VALUES (:user_id, :event_id, 'pending', :now_plus_5_min);

-- Try to take each requested seat, in ascending seat_id order
UPDATE seats
SET status = 'held', order_id = :order_id, hold_expires_at = :now_plus_5_min
WHERE seat_id = :seat_id
  AND event_id = :event_id
  AND (status = 'available'
       OR (status = 'held' AND hold_expires_at < :now));
-- rows affected = 1  -> I got the seat
-- rows affected = 0  -> someone else has it

-- If ANY seat affected 0 rows: ROLLBACK and answer 409 (nothing is held).
-- If all seats affected 1 row: set orders.total_cents, then COMMIT and answer 201.
COMMIT;
```

The `WHERE status = 'available'` is the check and the `SET status = 'held'` is the action, in the same statement. The database locks the row while one update runs. Here is what happens when Ana and Ben collide:

| Step | Ana | Ben | Seat 1101 |
|---|---|---|---|
| 1 | Sends the UPDATE | Sends the same UPDATE | available |
| 2 | Database locks the row and sets it to held, 1 row changed | Has to wait for the lock | held by Ana's order |
| 3 | COMMIT, gets 201 | Lock is released. The database re-checks the WHERE against the new row: status is now `held` and not expired, so 0 rows changed | held |
| 4 | | ROLLBACK, gets 409 "seat just taken" | held |

Only one person can win. The loser gets a clear message and picks another seat.

### Layer 2: the transaction makes it all-or-nothing

If someone asks for seats 1101 and 1102 and only 1101 is free, the whole transaction is rolled back, so no one is left with half an order. Seats are always updated in ascending `seat_id` order, so two people wanting the same pair of seats cannot lock them in opposite order and deadlock each other.

### Layer 3: constraints are the last line of defence

Even if my application code had a bug, the database would refuse a double sale:
- `CREATE UNIQUE INDEX one_valid_ticket_per_seat ... WHERE status = 'valid'` means a second valid ticket for the same seat is rejected by the database itself.
- `CHECK (status IN ('available', 'held', 'sold'))` blocks nonsense values.
- `CHECK (status = 'available' OR order_id IS NOT NULL)` means a held or sold seat always belongs to an order.
- `UNIQUE (event_id, section, row_label, seat_number)` stops the same physical seat existing twice.
- Foreign keys stop tickets from pointing at orders or seats that do not exist.

### Layer 4: holds expire, and paying re-checks the hold

- A hold lasts 5 minutes. A background worker runs every 30 seconds and frees expired holds. The `OR (status = 'held' AND hold_expires_at < :now)` part of the UPDATE also lets a seat be taken immediately if the worker has not run yet.
- When a person starts paying, the hold is extended once by 2 minutes, so a slow card page cannot lose them their seat.
- The final step runs in a transaction and only succeeds if the seats are still held by this order:

```sql
BEGIN;
UPDATE seats SET status = 'sold'
WHERE order_id = :order_id AND status = 'held' AND hold_expires_at > :now;
-- must change exactly as many rows as there are seats in the order, otherwise ROLLBACK

INSERT INTO tickets (order_id, seat_id, price_cents, qr_code)
VALUES (:order_id, :seat_id, :price_cents, :qr_token);   -- one row per seat

UPDATE orders SET status = 'paid', payment_ref = :payment_ref
WHERE order_id = :order_id AND status = 'pending';
COMMIT;
```

- The call to the payment provider happens **outside** the database transaction, so a slow payment never keeps rows locked.
- If a payment ever succeeds but the seats cannot be confirmed (a very rare case), the system refunds automatically instead of selling the seat twice.
- The `Idempotency-Key` on the payment request means a retry returns the same result instead of charging again.

---

## 6. Architecture

```
                         Users (browsers / phones)
                                    |
                                    v
        +-------------------------------------------------------+
        | 1. CDN: images, CSS/JS, cached event pages            |
        +---------------------------+---------------------------+
                                    |
                                    v
        +-------------------------------------------------------+
        | 2. Load balancer + rate limiter                       |
        +---------------------------+---------------------------+
                                    |
                                    v
        +-------------------------------------------------------+
        | 3. Waiting room (queue + admission tokens)            |
        |    only for hot sales; guards the hold and pay routes |
        +---------------------------+---------------------------+
                                    |
                                    v
        +-------------------------------------------------------+
        | 4. App servers (stateless, many copies)               |
        +--+------------+---------------+------------------+----+
           |            |               |                  |
           v            v               v                  v
   +-------------+ +------------+ +-------------+  +----------------+
   | 5. Cache    | | 6. Primary | | 7. Message  |  | 8. Payment     |
   | (Redis)     | | database   | | queue       |  | provider       |
   +-------------+ +-----+------+ +------+------+  +-------+--------+
                         |               |                 |
                         v               v                 | webhook back
                  +-------------+  +-------------+         | to app servers
                  | 6b. Read    |  | 7b. Workers |         |
                  | replicas    |  +-------------+         |
                  +-------------+                          v
```

### What each component does

1. **CDN (content delivery network).** Serves images, CSS, JavaScript and cached public pages (event lists and event details) from servers close to the user. Most of the 100:1 read traffic never reaches my own servers.
2. **Load balancer and rate limiter.** Spreads requests evenly over the app servers and sends traffic away from any server that is down. The rate limiter caps requests per account and per IP (for example, one seat-map refresh per second), which slows bots.
3. **Waiting room.** For a hot sale, visitors first land in a queue and see their position. Admitted users receive a signed token and are let in at a controlled pace (for example, at most 5,000 active shoppers at a time). Early arrivals are shuffled randomly, later arrivals are in order. Only people with a token can call the hold and pay routes. This is what protects the database.
4. **App servers.** Run the API from section 3. They are stateless, which means any copy can answer any request and no data lives on them. I add more copies before a big sale, and a crashed server loses nothing.
5. **Cache (Redis).** Holds event details, a snapshot of the seat map (refreshed every 1 to 2 seconds) and a counter of tickets remaining. When the counter reaches zero, "sold out" is answered from the cache without touching the database.
6. **Primary database (relational, such as PostgreSQL).** The only place that decides who gets a seat, using the transactions and constraints from section 5. **Read replicas** (6b) copy the data and answer less urgent reads, such as "my tickets" and searching events, so the primary is kept free for holds and payments.
7. **Message queue and workers.** After a payment, the app puts a job on the queue (send confirmation email, create QR codes) and replies to the user immediately. Workers also free expired holds every 30 seconds. If the email service is slow, nobody waits for it.
8. **Payment provider.** An outside service that handles the card and tells us the result by a response or a webhook. We never see or store card numbers.

### How it survives the big sale

- **Reads (about 3,300 per second, spikes near 10,000).** The CDN serves the static content and event pages. The seat map is served from the cache and rebuilt from a read replica every 1 to 2 seconds, so 200,000 people refreshing do not mean 200,000 database queries.
- **Writes (about 1,000 hold attempts per second if everyone came at once).** The waiting room flattens this to a rate that one primary database can handle, and the conditional UPDATE keeps each attempt small and fast.
- **The 180,000 people who will not get a seat.** Once the counter in the cache reaches zero, they receive "sold out" immediately and the database is not touched. People are not stuck waiting, which is also fairer.
- **Failures.** If an app server dies, the load balancer uses another one. If the cache dies, the app falls back to a read replica (slower but still correct). If the primary database fails, a replica is promoted. During that short time, holds fail with a "try again" message. I accept that, because refusing a request is better than selling a seat twice.

---

## 7. Trade-offs

**Trade-off 1: Strong consistency in one relational database versus a distributed NoSQL store.**
- Chosen: one primary relational database that decides every seat.
- Gained: simple, reliable transactions and constraints, so the double-booking rules in section 5 are easy to prove.
- Given up: all writes go through one primary, so write speed is limited by one machine (about 1,000 holds per second is within reach, but this should be load-tested). If TicketHub grows, I would split the data by `event_id`, because different events never compete for the same seat.

**Trade-off 2: A cached seat map (a little stale) versus a live one.**
- Chosen: the seat map is cached and refreshed every 1 to 2 seconds.
- Gained: speed, and the database is protected from 200,000 people refreshing.
- Given up: sometimes a person clicks a seat that was taken a second ago and gets a 409. This is acceptable because the database makes the final decision, so a stale map can never cause a double sale, only a polite "pick another seat".

**Trade-off 3: Hold length (5 minutes) - fairness versus convenience.**
- A long hold (for example 15 minutes) gives people time to pay, but seats stay locked by people who never finish, and bots can hoard seats.
- A short hold (for example 2 minutes) frees seats quickly but may time out people who are paying with a slow card.
- Chosen: 5 minutes, plus a one-time 2-minute extension once payment starts.

**Trade-off 4: A waiting room versus letting everyone in.**
- Gained: the database and servers are protected, and the order of people is fair and clear.
- Given up: extra complexity to build, and some people have to wait. A waiting room feels slower than a "just let everyone click" design, but that design would crash and would reward the fastest bots.
