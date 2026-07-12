from langchain_openai import ChatOpenAI
from langchain_groq import ChatGroq
from config.config import LLM_PROVIDER, VLLM_BASE_URL, VLLM_MODEL_NAME, GROQ_API_KEY, MODEL_NAME

def get_llm():
    if LLM_PROVIDER == "groq":
        return ChatGroq(api_key=GROQ_API_KEY, model=MODEL_NAME, temperature=0)

    return ChatOpenAI(
        base_url=VLLM_BASE_URL,
        api_key="not-needed",  # vLLM ignores this; langchain_openai just requires a non-empty string
        model=VLLM_MODEL_NAME,
        temperature=0,
        max_tokens=512,
    )
