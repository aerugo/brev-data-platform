We want to set up an example project that demonstrates using the "central-bank-speeches" to create a data product with AI/LLM capabilities and present it in an interactive dashboard.

Dagster pipeline should do the following:
1. Set up a Dagster pipeline to ingest and process the "central-bank-speeches" dataset from Kaggle. As the first step of the Dagster pipeline we get the dataframe, add it to our object storage and version it with LakeFS.
2. As the first step of the pipeline, we will use an NIM to generate embeddings (need to add an embedding model to the NIM configuration) for the speeches. 
3. As a second step of the Dagster pipeline, we use a NIM LLM to identify if the speeches contain any discussion of tarriffs as a binary 1 or 0.
4. Save the resulting dataframe as a Data Product in LakeFS.
5. Save the text and embeddings to Weaviate (needs to be set up in this project), connected back to the data product polars data frame.  
6. Create a vector search index in Weaviate using the generated embeddings.

We then set up another Dagster pipeline to generate a synthetic twin of the data product for sharing by using NVIDIA Safe Synthesizer. We make the validation report available as a data product in LakeFS. We generate new embeddings for the synthetic data and a separate Weaviate text+embedding index.

Then, set up a Marimo dashboard with Jupyter hubs to allow users to interactively query the Weaviate vector search index and visualize the results. Allow switching between real and synthetic data products.

Plan this major project in detail, including code snippets for the Dagster pipelines, NIM configuration, Weaviate setup, and Marimo dashboard configuration. Really understand how our systems work together by exploring the current repository, which sets up the entire stack from scratch on NVIDIA Brev with Dagster, NIM, LakeFS, Weaviate, and Marimo.

Below is an example of how to load the "central-bank-speeches" dataset using KaggleHub with Polars:

```python
# Install dependencies as needed:
# pip install kagglehub[polars-datasets]
import kagglehub
from kagglehub import KaggleDatasetAdapter

# Set the path to the file you'd like to load
file_path = ""

# Load the latest version
lf = kagglehub.load_dataset(
  KaggleDatasetAdapter.POLARS,
  "davidgauthier/central-bank-speeches",
  file_path,
  # Provide any additional arguments like
  # sql_query, polars_frame_type, or 
  # polars_kwargs.
  # See the documenation for more information:
  # https://github.com/Kaggle/kagglehub/blob/main/README.md#kaggledatasetadapterpolars
)

print("First 5 records:", lf.collect().head())
```