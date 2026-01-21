from passlib.context import CryptContext

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(password: str) -> str:
    # truncate to 72 bytes before hashing
    truncated = password[:72]  # first 72 characters
    return pwd_context.hash(truncated)

def verify_password(password: str, password_hash: str) -> bool:
    return pwd_context.verify(password, password_hash)
