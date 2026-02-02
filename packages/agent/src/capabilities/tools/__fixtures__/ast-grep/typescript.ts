// TypeScript fixture for ast-grep tests

interface User {
  id: number;
  name: string;
  email: string;
}

interface ApiResponse<T> {
  data: T;
  status: number;
  message: string;
}

type Handler<T> = (input: T) => Promise<void>;

async function fetchUser(id: number): Promise<User> {
  console.log("Fetching user:", id);
  return {
    id,
    name: "Test User",
    email: "test@example.com"
  };
}

async function saveUser(user: User): Promise<ApiResponse<User>> {
  console.log("Saving user:", user.name);
  return {
    data: user,
    status: 200,
    message: "Success"
  };
}

function processData<T>(data: T, handler: Handler<T>): void {
  handler(data);
}

class UserService {
  private users: Map<number, User> = new Map();

  async getUser(id: number): Promise<User | undefined> {
    return this.users.get(id);
  }

  async createUser(user: User): Promise<User> {
    this.users.set(user.id, user);
    console.log("Created user:", user.id);
    return user;
  }

  async deleteUser(id: number): Promise<boolean> {
    return this.users.delete(id);
  }
}

// Type guards
function isUser(obj: unknown): obj is User {
  return (
    typeof obj === "object" &&
    obj !== null &&
    "id" in obj &&
    "name" in obj
  );
}

// Null checks
function validateUser(user: User | null): boolean {
  if (user === null) {
    return false;
  }
  if (user.name === null) {
    return false;
  }
  return true;
}

// Equality checks
function compareIds(a: number, b: number): boolean {
  return a === a && b === b && a === b;
}

export { UserService, fetchUser, saveUser };
export type { User, ApiResponse };
