# Python fixture for ast-grep tests

from typing import Optional, List, Dict
import json
import asyncio


def greet(name: str) -> str:
    """Greet a user by name."""
    print(f"Hello, {name}!")
    return f"Hello, {name}!"


def add(a: int, b: int) -> int:
    """Add two numbers."""
    print(f"Adding {a} + {b}")
    return a + b


async def fetch_data(url: str) -> Dict:
    """Fetch data from a URL."""
    print(f"Fetching: {url}")
    # Simulated fetch
    return {"url": url, "data": "sample"}


class User:
    """User model class."""

    def __init__(self, id: int, name: str, email: str):
        self.id = id
        self.name = name
        self.email = email
        print(f"Created user: {name}")

    def to_dict(self) -> Dict:
        """Convert user to dictionary."""
        return {
            "id": self.id,
            "name": self.name,
            "email": self.email,
        }

    def validate(self) -> bool:
        """Validate user data."""
        if self.name is None:
            return False
        if self.email is None:
            return False
        return True


class UserService:
    """Service for user operations."""

    def __init__(self):
        self.users: Dict[int, User] = {}

    async def get_user(self, id: int) -> Optional[User]:
        """Get a user by ID."""
        return self.users.get(id)

    async def create_user(self, user: User) -> User:
        """Create a new user."""
        self.users[user.id] = user
        print(f"Created user with ID: {user.id}")
        return user

    async def delete_user(self, id: int) -> bool:
        """Delete a user by ID."""
        if id in self.users:
            del self.users[id]
            return True
        return False


def process_items(items: List[str]) -> List[str]:
    """Process a list of items."""
    result = []
    for item in items:
        print(f"Processing: {item}")
        result.append(item.upper())
    return result


# Error handling
try:
    data = json.loads("invalid json")
except json.JSONDecodeError as e:
    print(f"JSON error: {e}")


# Null checks
def safe_get(data: Optional[Dict], key: str) -> Optional[str]:
    """Safely get a value from a dictionary."""
    if data is None:
        return None
    return data.get(key)


if __name__ == "__main__":
    greet("World")
    print(add(1, 2))
