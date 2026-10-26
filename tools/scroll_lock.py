#!/usr/bin/env python3
"""
Scroll Lock: Password-Protected Integrity Engine for Iume Scrolling Physics.

Guards verified perfect scrolling physics against accidental or unauthorized edits.
Requires password authentication to unlock modifications.
"""

import os
import sys
import json
import time
import hmac
import hashlib
import secrets
import argparse
import getpass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / ".scroll_lock.json"
TOKEN_PATH = REPO_ROOT / ".scroll_lock.token"

START_MARKER_PREFIX = "// [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE"
END_MARKER_PREFIX = "// [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE"

PBKDF2_ITERATIONS = 200_000

# Targeted files containing the verified perfect scrolling engine
TRACKED_FILES = [
    "Sources/IumeCore/Controller/ScrollController.swift",
    "Sources/IumeCore/Models/CoreModels.swift",
    "Sources/IumeCore/Settings/SettingsStore.swift",
    "Sources/IumeCore/Persistence/SettingsMemoryManager.swift",
    "Sources/IumeCore/Workspace/WorkspaceManager.swift",
    "Sources/IumeCore/UI/LaunchHUDController.swift",
    "Sources/IumeCore/UI/StatusBarController.swift",
]


def hash_password(password: str, salt: bytes) -> str:
    dk = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt,
        PBKDF2_ITERATIONS
    )
    return dk.hex()


def verify_password(password: str, salt_hex: str, hash_hex: str) -> bool:
    salt = bytes.fromhex(salt_hex)
    computed = hash_password(password, salt)
    return hmac.compare_digest(computed, hash_hex)


def extract_locked_sections(file_path: Path) -> List[Dict]:
    """
    Extracts all locked sections demarcated by START_MARKER and END_MARKER.
    Returns list of { "id": section_id, "start_line": int, "end_line": int, "sha256": hash }
    """
    if not file_path.exists():
        return []

    with open(file_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    sections = []
    in_section = False
    current_section_id = ""
    current_lines = []
    start_line_num = 0

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()
        if stripped.startswith(START_MARKER_PREFIX):
            if in_section:
                raise ValueError(f"Nested locked section detected in {file_path} at line {idx}")
            in_section = True
            start_line_num = idx
            current_lines = []
            # Extract section id if specified, e.g. // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:stepDeceleration]
            if ":" in stripped[:-1]:
                parts = stripped.rstrip("]").split(":")
                current_section_id = parts[-1].strip()
            else:
                current_section_id = f"section_{len(sections) + 1}"
            continue

        if stripped.startswith(END_MARKER_PREFIX):
            if not in_section:
                raise ValueError(f"End marker without start marker in {file_path} at line {idx}")
            in_section = False
            # Calculate SHA-256 of the exact enclosed text
            section_content = "".join(current_lines)
            content_hash = hashlib.sha256(section_content.encode("utf-8")).hexdigest()
            sections.append({
                "id": current_section_id,
                "start_line": start_line_num,
                "end_line": idx,
                "sha256": content_hash,
                "length_lines": len(current_lines)
            })
            current_lines = []
            continue

        if in_section:
            current_lines.append(line)

    if in_section:
        raise ValueError(f"Unclosed locked section starting at line {start_line_num} in {file_path}")

    return sections


def load_config() -> Optional[Dict]:
    if not CONFIG_PATH.exists():
        return None
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error reading {CONFIG_PATH}: {e}", file=sys.stderr)
        return None


def save_config(config: Dict):
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)


def is_token_valid(config: Dict) -> Tuple[bool, str]:
    """Check if an unlock token exists and is valid."""
    if not TOKEN_PATH.exists():
        return False, "No active unlock session"

    try:
        with open(TOKEN_PATH, "r", encoding="utf-8") as f:
            token_data = json.load(f)

        secret = config.get("token_secret", "")
        expires_at = token_data.get("expires_at", 0)
        nonce = token_data.get("nonce", "")
        signature = token_data.get("signature", "")

        if time.time() > expires_at:
            TOKEN_PATH.unlink(missing_ok=True)
            return False, "Unlock token has expired"

        expected_sig = hmac.new(
            secret.encode("utf-8"),
            f"{expires_at}:{nonce}".encode("utf-8"),
            hashlib.sha256
        ).hexdigest()

        if not hmac.compare_digest(signature, expected_sig):
            TOKEN_PATH.unlink(missing_ok=True)
            return False, "Unlock token signature invalid"

        remaining_sec = int(expires_at - time.time())
        return True, f"Unlocked (valid for {remaining_sec}s remaining)"
    except Exception as e:
        TOKEN_PATH.unlink(missing_ok=True)
        return False, f"Invalid token file: {e}"


def issue_token(config: Dict, duration_seconds: int = 900) -> None:
    secret = config.get("token_secret")
    if not secret:
        secret = secrets.token_hex(32)
        config["token_secret"] = secret
        save_config(config)

    expires_at = time.time() + duration_seconds
    nonce = secrets.token_hex(16)
    signature = hmac.new(
        secret.encode("utf-8"),
        f"{expires_at}:{nonce}".encode("utf-8"),
        hashlib.sha256
    ).hexdigest()

    token_data = {
        "issued_at": time.time(),
        "expires_at": expires_at,
        "nonce": nonce,
        "signature": signature
    }
    with open(TOKEN_PATH, "w", encoding="utf-8") as f:
        json.dump(token_data, f, indent=2)


def cmd_set_password(args):
    config = load_config() or {
        "version": 1,
        "algorithm": "PBKDF2-HMAC-SHA256",
        "iterations": PBKDF2_ITERATIONS,
        "token_secret": secrets.token_hex(32),
        "files": {},
        "created_at": time.time(),
        "description": "Iume Perfect Scrolling Physics Engine Lock Manifest"
    }

    if "password_hash" in config and not args.force:
        # Prompt for existing password
        current_pass = args.current_password or getpass.getpass("Enter current lock password: ")
        if not verify_password(current_pass, config["salt"], config["password_hash"]):
            print("❌ Authentication failed: Current password incorrect.", file=sys.stderr)
            sys.exit(1)

    new_pass = args.password
    if not new_pass:
        new_pass = getpass.getpass("Enter new lock password: ")
        confirm_pass = getpass.getpass("Confirm new lock password: ")
        if new_pass != confirm_pass:
            print("❌ Passwords do not match.", file=sys.stderr)
            sys.exit(1)

    if len(new_pass) < 6:
        print("❌ Password must be at least 6 characters long.", file=sys.stderr)
        sys.exit(1)

    salt = secrets.token_bytes(16)
    config["salt"] = salt.hex()
    config["password_hash"] = hash_password(new_pass, salt)
    config["password_updated_at"] = time.time()
    save_config(config)
    print("✅ Lock password successfully set.")


def cmd_lock(args):
    config = load_config()
    if not config or "password_hash" not in config:
        print("⚠️ No password set yet. Please set a password first with 'scroll_lock.py set-password'.")
        sys.exit(1)

    # Check if authorized (either token or password)
    valid_token, _ = is_token_valid(config)
    if not valid_token:
        password = args.password or getpass.getpass("Enter lock password to engage/update locks: ")
        if not verify_password(password, config["salt"], config["password_hash"]):
            print("❌ Authentication failed: Password incorrect.", file=sys.stderr)
            sys.exit(1)

    # Scan and hash all tracked files
    tracked_manifest = {}
    total_sections = 0

    for rel_path in TRACKED_FILES:
        full_path = REPO_ROOT / rel_path
        if not full_path.exists():
            print(f"⚠️ Tracked file not found: {rel_path}", file=sys.stderr)
            continue

        try:
            sections = extract_locked_sections(full_path)
            tracked_manifest[rel_path] = sections
            total_sections += len(sections)
        except Exception as e:
            print(f"❌ Error scanning {rel_path}: {e}", file=sys.stderr)
            sys.exit(1)

    config["files"] = tracked_manifest
    config["last_locked_at"] = time.time()
    config["total_sections"] = total_sections
    save_config(config)

    # Invalidate any lingering unlock tokens
    TOKEN_PATH.unlink(missing_ok=True)

    print(f"🔒 PERFECT SCROLLING ENGINE LOCKED: {total_sections} physics sections locked across {len(tracked_manifest)} files.")


def cmd_verify(args) -> int:
    config = load_config()
    if not config or "files" not in config or not config["files"]:
        print("⚠️ Scroll lock manifest not initialized. Run 'scroll_lock.py lock' first.")
        return 0

    valid_token, token_msg = is_token_valid(config)
    if valid_token:
        if args.verbose:
            print(f"🔓 BYPASS ACTIVE: {token_msg}. Modifications currently authorized.")
        return 0

    tampered_sections = []

    for rel_path, expected_sections in config["files"].items():
        full_path = REPO_ROOT / rel_path
        if not full_path.exists():
            tampered_sections.append({
                "file": rel_path,
                "id": "FILE_DELETED",
                "reason": "File was deleted or moved"
            })
            continue

        try:
            current_sections = extract_locked_sections(full_path)
        except Exception as e:
            tampered_sections.append({
                "file": rel_path,
                "id": "SYNTAX_ERROR",
                "reason": f"Failed to parse markers: {e}"
            })
            continue

        curr_map = {s["id"]: s for s in current_sections}
        exp_map = {s["id"]: s for s in expected_sections}

        for sec_id, exp in exp_map.items():
            if sec_id not in curr_map:
                tampered_sections.append({
                    "file": rel_path,
                    "id": sec_id,
                    "reason": "Locked section missing or marker altered"
                })
            elif curr_map[sec_id]["sha256"] != exp["sha256"]:
                tampered_sections.append({
                    "file": rel_path,
                    "id": sec_id,
                    "reason": f"Content modified (hash mismatch: expected {exp['sha256'][:8]}..., got {curr_map[sec_id]['sha256'][:8]}...)"
                })

    if not tampered_sections:
        if args.verbose:
            print("✅ All locked scrolling physics sections verified intact.")
        return 0

    print("\n" + "=" * 70, file=sys.stderr)
    print("🚨 [SCROLL LOCK] UNAUTHORIZED MODIFICATION DETECTED IN LOCKED SECTIONS!", file=sys.stderr)
    print("The verified perfect scrolling physics engine is protected by password.", file=sys.stderr)
    print("=" * 70, file=sys.stderr)
    for item in tampered_sections:
        print(f"  • {item['file']} [{item['id']}]: {item['reason']}", file=sys.stderr)
    print("=" * 70, file=sys.stderr)
    print("\nTo authorize changes, you MUST unlock with your scrolling password:", file=sys.stderr)
    print("  python3 tools/scroll_lock.py unlock", file=sys.stderr)
    print("or provide password to agent if automated.\n", file=sys.stderr)
    return 1


def cmd_unlock(args):
    config = load_config()
    if not config or "password_hash" not in config:
        print("❌ Scroll lock is not configured. Set password first with 'scroll_lock.py set-password'.", file=sys.stderr)
        sys.exit(1)

    password = args.password
    if not password:
        password = getpass.getpass("Enter scroll lock authorization password: ")

    if not verify_password(password, config["salt"], config["password_hash"]):
        print("❌ Authentication failed: Password incorrect.", file=sys.stderr)
        sys.exit(1)

    duration = args.duration or 900  # Default 15 mins
    issue_token(config, duration_seconds=duration)
    print(f"🔓 ACCESS GRANTED: Scrolling physics unlocked for editing for {duration // 60} minutes ({duration}s).")
    print("After editing, re-verify and lock with:")
    print("  python3 tools/scroll_lock.py relock")


def cmd_relock(args):
    config = load_config()
    if not config or "password_hash" not in config:
        print("❌ Scroll lock is not configured.", file=sys.stderr)
        sys.exit(1)

    valid_token, _ = is_token_valid(config)
    if not valid_token:
        password = args.password or getpass.getpass("Enter password to relock and update hashes: ")
        if not verify_password(password, config["salt"], config["password_hash"]):
            print("❌ Authentication failed: Password incorrect.", file=sys.stderr)
            sys.exit(1)

    # Remove token
    TOKEN_PATH.unlink(missing_ok=True)

    # Recompute hashes
    tracked_manifest = {}
    total_sections = 0
    for rel_path in TRACKED_FILES:
        full_path = REPO_ROOT / rel_path
        if full_path.exists():
            sections = extract_locked_sections(full_path)
            tracked_manifest[rel_path] = sections
            total_sections += len(sections)

    config["files"] = tracked_manifest
    config["last_locked_at"] = time.time()
    config["total_sections"] = total_sections
    save_config(config)

    print(f"🔒 RELOCKED: Scrolling physics engine secured ({total_sections} sections updated and locked).")


def cmd_status(args):
    config = load_config()
    if not config:
        print("Scroll lock status: NOT INITIALIZED")
        return

    valid_token, token_msg = is_token_valid(config)
    print("==================================================================")
    print("  IUME SCROLLING PHYSICS ENGINE LOCK STATUS")
    print("==================================================================")
    print(f"  Overall Status:  {'🔓 UNLOCKED (' + token_msg + ')' if valid_token else '🔒 LOCKED'}")
    print(f"  Password Set:    {'Yes' if 'password_hash' in config else 'No'}")
    print(f"  Total Sections:  {config.get('total_sections', 0)}")
    print(f"  Last Locked:     {time.ctime(config.get('last_locked_at', 0)) if 'last_locked_at' in config else 'Never'}")
    print("------------------------------------------------------------------")
    print("  Tracked Files:")
    for rel_path, sections in config.get("files", {}).items():
        print(f"    • {rel_path} ({len(sections)} locked sections)")
        for sec in sections:
            print(f"        - {sec['id']} (lines {sec['start_line']}..{sec['end_line']}, sha: {sec['sha256'][:10]}...)")
    print("==================================================================")


def main():
    parser = argparse.ArgumentParser(description="Iume Perfect Scrolling Engine Lock & Password Authorization Guard")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # set-password
    p_setpass = subparsers.add_parser("set-password", help="Set or update scrolling engine password")
    p_setpass.add_argument("--password", help="New password")
    p_setpass.add_argument("--current-password", help="Current password if updating")
    p_setpass.add_argument("--force", action="store_true", help="Force set without checking old password")
    p_setpass.set_defaults(func=cmd_set_password)

    # lock
    p_lock = subparsers.add_parser("lock", help="Scan and engage lock on all marked physics sections")
    p_lock.add_argument("--password", help="Lock password")
    p_lock.set_defaults(func=cmd_lock)

    # verify
    p_verify = subparsers.add_parser("verify", help="Verify integrity of all locked sections")
    p_verify.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    p_verify.set_defaults(func=lambda args: sys.exit(cmd_verify(args)))

    # unlock
    p_unlock = subparsers.add_parser("unlock", help="Unlock editing for a temporary duration using password")
    p_unlock.add_argument("--password", help="Authorization password")
    p_unlock.add_argument("--duration", type=int, default=900, help="Duration in seconds (default 900s / 15m)")
    p_unlock.set_defaults(func=cmd_unlock)

    # relock
    p_relock = subparsers.add_parser("relock", help="Invalidate token, recompute hashes, and lock sections")
    p_relock.add_argument("--password", help="Authorization password")
    p_relock.set_defaults(func=cmd_relock)

    # status
    p_status = subparsers.add_parser("status", help="Display lock status of scrolling physics")
    p_status.set_defaults(func=cmd_status)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
