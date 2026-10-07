// Select all the elements
const noteText = document.getElementById("note-text");
const charCount = document.getElementById("char-count");
const wordCount = document.getElementById("word-count");
const clearBtn = document.getElementById("clear-btn");
const themeToggle = document.getElementById("theme-toggle");

const MAX_CHARS = 200;
const WARNING_LIMIT = 180;

// Update both counters and the warning classes
function updateCounts() {
  const text = noteText.value;
  const chars = text.length;

  // Split on any whitespace; an empty or all-space note has 0 words
  const trimmed = text.trim();
  let words = 0;
  if (trimmed !== "") {
    words = trimmed.split(/\s+/).length;
  }

  charCount.textContent = chars + " / " + MAX_CHARS + " characters";
  wordCount.textContent = words + " words";

  charCount.classList.toggle("warning", chars > WARNING_LIMIT);
  charCount.classList.toggle("over", chars > MAX_CHARS);
}

// Save the draft so it survives a refresh
function saveDraft() {
  localStorage.setItem("draft", noteText.value);
}

// Empty the textarea, reset the counters and remove the saved draft
function clearNote() {
  noteText.value = "";
  updateCounts();
  localStorage.removeItem("draft");
}

// Switch the page and the button label to match the theme
function applyTheme(isDark) {
  document.body.classList.toggle("dark", isDark);
  if (isDark) {
    themeToggle.textContent = "Light mode";
  } else {
    themeToggle.textContent = "Dark mode";
  }
}

// Every time the text changes: update the counters and save the draft
noteText.addEventListener("input", function () {
  updateCounts();
  saveDraft();
});

// Escape inside the textarea clears it
noteText.addEventListener("keydown", function (event) {
  if (event.key === "Escape") {
    clearNote();
  }
});

clearBtn.addEventListener("click", clearNote);

// Toggle dark mode and remember the choice
themeToggle.addEventListener("click", function () {
  const isDark = !document.body.classList.contains("dark");
  applyTheme(isDark);
  localStorage.setItem("theme", isDark ? "dark" : "light");
});

// On page load: restore the saved draft and theme, then update the counters
const savedDraft = localStorage.getItem("draft");
if (savedDraft !== null) {
  noteText.value = savedDraft;
}

applyTheme(localStorage.getItem("theme") === "dark");
updateCounts();
