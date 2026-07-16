import streamlit as st
from pipeline.pipeline import AnimeRecommendationPipeline
from dotenv import load_dotenv

st.set_page_config(page_title="Anime Recommnder",layout="wide")

load_dotenv()

@st.cache_resource
def init_pipeline():
    return AnimeRecommendationPipeline()

pipeline = init_pipeline()

st.title("Anime Recommender System")

query = st.text_input("Enter your anime prefernces eg. : light hearted anime with school settings")
if query:
    # The serve pool scales 0->1, so the first query after an idle period waits on a
    # node scale-up plus a CPU model load before any tokens come back.
    with st.spinner("Fetching recommendations for you..... (the first query can take a few minutes while the model warms up)"):
        response = pipeline.recommend(query)
        st.markdown("### Recommendations")
        st.write(response)