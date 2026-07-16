import logging
import os
import sys
from datetime import datetime

# Stream by default: the container runs with a read-only rootfs (no writable /app/logs)
# and k8s collects stdout. Set LOGS_DIR to also write a dated file for local runs.
LOGS_DIR = os.getenv("LOGS_DIR")

handlers = [logging.StreamHandler(sys.stdout)]

if LOGS_DIR:
    os.makedirs(LOGS_DIR, exist_ok=True)
    LOG_FILE = os.path.join(LOGS_DIR, f"log_{datetime.now().strftime('%Y-%m-%d')}.log")
    handlers.append(logging.FileHandler(LOG_FILE))

logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(message)s',
    level=logging.INFO,
    handlers=handlers
)

def get_logger(name):
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    return logger
