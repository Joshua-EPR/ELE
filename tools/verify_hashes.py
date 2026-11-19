
import hashlib
import sys
import os

def calculate_sha256(file_path):
    sha256_hash = hashlib.sha256()
    with open(file_path, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()

def verify_hashes(hash_file):
    with open(hash_file, "r") as f:
        for line in f:
            parts = line.strip().split("  ")
            if len(parts) != 2:
                continue
            expected_hash, file_path = parts
            if not os.path.exists(file_path):
                print(f"File not found: {file_path}")
                continue
            actual_hash = calculate_sha256(file_path)
            if actual_hash == expected_hash:
                print(f"Verified: {file_path}")
            else:
                print(f"FAILED: {file_path} (Expected {expected_hash}, got {actual_hash})")
                sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python verify_hashes.py <hash_file>")
        sys.exit(1)
    verify_hashes(sys.argv[1])
