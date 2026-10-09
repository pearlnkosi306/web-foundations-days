const API_URL = "https://jsonplaceholder.typicode.com/users";

const loadButton = document.getElementById("load-users");
const filterInput = document.getElementById("filter-input");
const statusMessage = document.getElementById("status");
const usersList = document.getElementById("users-list");

// All the users that were fetched. The filter works on this array,
// so typing in the box never makes a new request.
let allUsers = [];

async function loadUsers() {
  statusMessage.textContent = "Loading users...";
  loadButton.disabled = true;

  try {
    const response = await fetch(API_URL);

    if (!response.ok) {
      throw new Error("Server responded with status " + response.status);
    }

    allUsers = await response.json();

    // Respect any text already typed in the filter box
    const matches = getMatches(filterInput.value);
    renderUsers(matches);
    showResultMessage(matches);
  } catch (error) {
    allUsers = [];
    renderUsers([]);
    statusMessage.textContent = "Error: could not load users. " + error.message;
  } finally {
    loadButton.disabled = false;
  }
}

function renderUsers(list) {
  usersList.textContent = "";

  list.forEach(function (user) {
    const item = document.createElement("li");

    const name = document.createElement("strong");
    name.textContent = user.name;
    item.appendChild(name);

    const email = document.createElement("div");
    email.textContent = "Email: " + user.email;
    item.appendChild(email);

    const city = document.createElement("div");
    city.textContent = "City: " + user.address.city;
    item.appendChild(city);

    const company = document.createElement("div");
    company.textContent = "Company: " + user.company.name;
    item.appendChild(company);

    usersList.appendChild(item);
  });
}

function getMatches(text) {
  const search = text.trim().toLowerCase();

  return allUsers.filter(function (user) {
    return user.name.toLowerCase().includes(search);
  });
}

function showResultMessage(matches) {
  if (matches.length === 0) {
    statusMessage.textContent = "No users match your filter.";
  } else if (filterInput.value.trim() === "") {
    statusMessage.textContent = "Loaded " + allUsers.length + " users.";
  } else {
    statusMessage.textContent =
      "Showing " + matches.length + " of " + allUsers.length + " users.";
  }
}

function handleFilter() {
  // Nothing to filter until the users have been loaded
  if (allUsers.length === 0) {
    return;
  }

  const matches = getMatches(filterInput.value);
  renderUsers(matches);
  showResultMessage(matches);
}

loadButton.addEventListener("click", loadUsers);
filterInput.addEventListener("input", handleFilter);
