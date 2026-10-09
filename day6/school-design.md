# School Database Design

The database has three tables: `students`, `courses` and `enrolments`. The SQL is in `school.sql`.

## Tables

**students** has one row for each student.
- `student_id` is the primary key.
- `first_name` and `last_name` are `NOT NULL` because every student needs a name.
- `email` is `NOT NULL` and `UNIQUE`, so two students cannot share the same email.

**courses** has one row for each course.
- `course_id` is the primary key.
- `title` is `NOT NULL`.
- `credits` is `NOT NULL` and must be more than 0.

**enrolments** has one row each time a student is enrolled on a course. It is the join table.
- `enrolment_id` is the primary key.
- `student_id` is a foreign key to `students`, and `course_id` is a foreign key to `courses`. Both are `NOT NULL`.
- `grade` is a number from 0 to 100. It can be `NULL` because a student has no grade when they first enrol.
- `UNIQUE (student_id, course_id)` stops the same student enrolling on the same course twice.

## Relationships

- **students to enrolments is one-to-many.** One student can have many enrolments, but each enrolment belongs to only one student.
- **courses to enrolments is one-to-many.** One course can have many enrolments, but each enrolment is for only one course.
- **students to courses is many-to-many.** A student takes many courses, and a course has many students.

A many-to-many relationship needs a join table because a single column cannot store it properly. If I put a list of course ids in the students table, I could not use foreign keys or joins on it. If I repeated the student on a new row for each course, I would copy their name and email many times. The join table fixes this: each row is one pair of student and course. The grade also belongs in this table, because it is not about the student alone or the course alone. It is about that student on that course.

## Index

I would add an index on `enrolments(course_id)`:

```sql
CREATE INDEX idx_enrolments_course_id ON enrolments (course_id);
```

The `UNIQUE (student_id, course_id)` rule already creates an index that starts with `student_id`, so finding the courses for one student is already fast. But "all students on one course" and "number of students per course" search by `course_id`, and that index does not help with that. Without a new index, SQLite has to read every row in `enrolments`. This is fine for 8 rows, but a real school would have thousands. The cost of the index is a bit more storage and slightly slower inserts, which is worth it because the table is read much more often than it is changed.

## SQL or NoSQL?

I would choose SQL for this system. The data is structured, and the relationships between students and courses are the most important part. SQL lets the database enforce the rules itself: foreign keys stop an enrolment for a student or course that does not exist, `UNIQUE` stops duplicate emails and duplicate enrolments, and `NOT NULL` stops missing names. With NoSQL, that checking would mostly have to be done in the application code. The questions we need to ask, like students per course or students with no enrolments, are joins and counts, which SQL is designed for. In a document database I would probably store each course inside every student document (or the other way round), so the same course title would be copied in many places. Renaming a course would mean updating all of those copies, and some could be missed. SQL also has transactions, so a change like enrolling a student and updating a record either fully happens or does not happen at all. NoSQL is a better choice when the data has no fixed shape, changes structure often, or has to spread across many servers at a huge scale. A school's students, courses and grades do not fit that description.
