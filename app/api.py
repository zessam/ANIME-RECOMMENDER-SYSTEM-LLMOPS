"""FastAPI interface to the anime recommender.

The Streamlit UI (app/app.py) is for humans; this is the programmatic endpoint
that clients — and security scanners like garak — call. Same pipeline underneath,
so testing this endpoint tests the real app (retriever + prompt_template.py + LLM).

Run:  uvicorn app.api:app --host 0.0.0.0 --port 8600
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from pydantic import BaseModel

from pipeline.pipeline import AnimeRecommendationPipeline

_state = {}


@asynccontextmanager
async def lifespan(_: FastAPI):
    # Build the RAG pipeline once at startup (loads Chroma + embeddings).
    _state["pipeline"] = AnimeRecommendationPipeline()
    yield
    _state.clear()


app = FastAPI(title="Anime Recommender API", lifespan=lifespan)


class RecommendRequest(BaseModel):
    prompt: str


class RecommendResponse(BaseModel):
    output: str


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/recommend", response_model=RecommendResponse)
def recommend(req: RecommendRequest):
    """Same call the Streamlit UI makes, exposed as plain HTTP JSON."""
    output = _state["pipeline"].recommend(req.prompt)
    return {"output": output}
