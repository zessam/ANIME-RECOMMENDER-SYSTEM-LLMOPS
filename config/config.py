import os
from dotenv import load_dotenv

load_dotenv()

GROQ_API_URL = os.getenv("GROQ_API_URL")
MODEL_NAME = "llama-3.1-8b-instant"

