# Library API Design

A REST API for a library's **books** resource. All requests and responses use JSON.

## Base URL

- `https://api.examplelibrary.com`
- The resource is the plural noun `books`, so paths are `/books` and `/books/{id}`
- The HTTP method says what to do; the path never contains a verb

## Book object

- `id` - number, set by the server
- `title` - string, required
- `author` - string, required
- `isbn` - string, optional
- `publishedYear` - number, optional

## Endpoints

### 1. List books

- **Method:** GET
- **Path:** `/books`
- **Description:** Returns all books in the library.
- **Request body:** none
- **Success status:** 200 OK

### 2. Get one book

- **Method:** GET
- **Path:** `/books/{id}`
- **Description:** Returns the single book with the given id.
- **Request body:** none
- **Success status:** 200 OK

### 3. Create a book

- **Method:** POST
- **Path:** `/books`
- **Description:** Adds a new book; the server assigns the id.
- **Example request body:**

```json
{
  "title": "Pride and Prejudice",
  "author": "Jane Austen",
  "isbn": "9780141439518",
  "publishedYear": 1813
}
```

- **Success status:** 201 Created

### 4. Update a book

- **Method:** PUT
- **Path:** `/books/{id}`
- **Description:** Replaces the details of an existing book with the data sent.
- **Example request body:**

```json
{
  "title": "Pride and Prejudice",
  "author": "Jane Austen",
  "isbn": "9780141439518",
  "publishedYear": 1813
}
```

- **Success status:** 200 OK

### 5. Delete a book

- **Method:** DELETE
- **Path:** `/books/{id}`
- **Description:** Removes the book with the given id from the library.
- **Request body:** none
- **Success status:** 204 No Content (nothing is returned)

### 6. List books by an author

- **Method:** GET
- **Path:** `/books?author=Jane%20Austen`
- **Description:** Returns only the books written by the author given in the `author` query parameter.
- **Request body:** none
- **Success status:** 200 OK
- **Note:** If the author has no books, the API still returns 200 OK with an empty list `[]`, because the list itself exists and is just empty.

## Error codes

### 400 Bad Request

- **Meaning:** The request is invalid, so the server cannot process it.
- **Example:** `POST /books` with a body that has no `title`, or `PUT /books/3` with `"publishedYear": "last year"` instead of a number.
- **Example response body:**

```json
{
  "error": "Bad Request",
  "message": "The field 'title' is required."
}
```

### 404 Not Found

- **Meaning:** The requested book does not exist.
- **Example:** `GET /books/9999` when no book has the id 9999. The same happens for `PUT /books/9999` and `DELETE /books/9999`.
- **Example response body:**

```json
{
  "error": "Not Found",
  "message": "No book with id 9999 exists."
}
```

## Summary

- `GET /books` - list all books - 200
- `GET /books/{id}` - get one book - 200
- `POST /books` - create a book - 201
- `PUT /books/{id}` - update a book - 200
- `DELETE /books/{id}` - delete a book - 204
- `GET /books?author=name` - list books by an author - 200
