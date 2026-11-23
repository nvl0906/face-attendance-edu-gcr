import os
from jose import jwt, JWTError
from typing import Annotated
import httpx
from pydantic import BaseModel
from fastapi import Request, HTTPException, status, Depends
from fastapi.security import OAuth2PasswordBearer
from supabase import AsyncClient

# --- Models ---
class User(BaseModel):
    userid: str
    username: str
    fullname: str
    is_institution: bool

# --- Configuration ---
JWT_SECRET = os.getenv("FAE_JWT_SECRET")
JWT_ALGORITHM = os.getenv("FAE_JWT_ALGORITHM")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="login")

# --- Authentication Logic ---
async def create_access_token(data: dict):
    # Standard practice: encode with the shared secret
    return jwt.encode(data, JWT_SECRET, algorithm=JWT_ALGORITHM)

async def get_current_user(token: Annotated[str, Depends(oauth2_scheme)]) -> User:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        # Validate data matches our User model automatically
        return User(**payload)
    except jwt.PyJWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, 
            detail="Could not validate credentials"
        )

async def verify_token(token: str):
    """Decode JWT token and raise if invalid"""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return payload
    except JWTError:
        return None

# Send sms
async def send_sms(to: str, message: str) -> Dict[str, Any]:
    """
    Sends an SMS using the MMSDuck API.
    """
    url = os.environ.get("SMS_URL")
    token = os.environ.get("SMS_KEY")
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    
    payload = {
        "to": str("+261") + str(to),
        "message": message
    }
    
    async with httpx.AsyncClient() as client:
        response = await client.post(url, headers=headers, json=payload)
        response.raise_for_status()
        return response.json()

# --- Resource Dependencies (Keep as def for speed) ---
async def get_supabase(request: Request) -> AsyncClient:
    return request.app.state.supabase


