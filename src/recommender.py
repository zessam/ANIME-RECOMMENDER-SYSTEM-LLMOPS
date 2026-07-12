from langchain.chains import RetrievalQA
from src.llm_provider import get_llm
from src.prompt_template import get_anime_prompt

class AnimeRecommender:
    def __init__(self,retriever):
        self.llm = get_llm()
        self.prompt = get_anime_prompt()

        self.qa_chain = RetrievalQA.from_chain_type(
            llm = self.llm,
            chain_type = "stuff",
            retriever = retriever,
            return_source_documents = True,
            chain_type_kwargs = {"prompt":self.prompt}
        )

    def get_recommendation(self,query:str):
        result = self.qa_chain({"query":query})
        return result['result']