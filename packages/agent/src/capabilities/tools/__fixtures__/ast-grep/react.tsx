// React/TSX fixture for ast-grep tests

import React, { useState, useEffect, useMemo, useCallback } from 'react';

interface ButtonProps {
  label: string;
  onClick: () => void;
  disabled?: boolean;
}

interface UserProfileProps {
  userId: number;
  onSave: (name: string) => void;
}

function Button({ label, onClick, disabled = false }: ButtonProps) {
  const handleClick = useCallback(() => {
    console.log("Button clicked:", label);
    onClick();
  }, [label, onClick]);

  return (
    <button
      onClick={handleClick}
      disabled={disabled}
      className="btn"
    >
      {label}
    </button>
  );
}

function UserProfile({ userId, onSave }: UserProfileProps) {
  const [name, setName] = useState<string>("");
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    console.log("UserProfile mounted for user:", userId);
    return () => {
      console.log("UserProfile unmounted");
    };
  }, [userId]);

  useEffect(() => {
    async function fetchData() {
      setLoading(true);
      try {
        const response = await fetch(`/api/users/${userId}`);
        const data = await response.json();
        setName(data.name);
      } catch (err) {
        setError("Failed to load user");
        console.log("Error fetching user:", err);
      } finally {
        setLoading(false);
      }
    }
    fetchData();
  }, [userId]);

  const displayName = useMemo(() => {
    return name.toUpperCase();
  }, [name]);

  const handleSave = useCallback(() => {
    console.log("Saving user:", name);
    onSave(name);
  }, [name, onSave]);

  if (loading) {
    return <div>Loading...</div>;
  }

  if (error) {
    return <div className="error">{error}</div>;
  }

  return (
    <div className="user-profile">
      <h1>{displayName}</h1>
      <input
        type="text"
        value={name}
        onChange={(e) => setName(e.target.value)}
      />
      <Button label="Save" onClick={handleSave} />
    </div>
  );
}

// Custom hook
function useUser(userId: number) {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch(`/api/users/${userId}`)
      .then(res => res.json())
      .then(data => {
        setUser(data);
        setLoading(false);
      });
  }, [userId]);

  return { user, loading };
}

export { Button, UserProfile, useUser };
