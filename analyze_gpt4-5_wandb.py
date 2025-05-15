import os
import re
import base64
import pandas as pd
from collections import defaultdict
from dotenv import load_dotenv
import wandb
from openai import OpenAI

# Load environment variables
load_dotenv()
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
wandb.login(key=os.getenv("WANDB_API_KEY"))

# Load background text
with open("background.txt", "r") as f:
    reference_text = f.read()

# Constants
date_pattern = re.compile(r'(\d{8})_\d{6}$')
image_extensions = (".jpg", ".jpeg", ".png", ".webp", ".gif")
csv_extensions = (".csv",)
base_directory = "."

# Group files by date
grouped_files = defaultdict(lambda: {"images": [], "csvs": []})

for root, dirs, files in os.walk(base_directory):
    if "first_old" in root.split(os.sep):
        continue

    match = date_pattern.search(root)
    if not match:
        continue

    date_key = match.group(1)

    for file in files:
        ext = os.path.splitext(file)[1].lower()
        full_path = os.path.join(root, file)

        if ext in image_extensions:
            grouped_files[date_key]["images"].append(full_path)
        elif ext in csv_extensions:
            grouped_files[date_key]["csvs"].append(full_path)

# Process per date
for date, data in grouped_files.items():
    run = wandb.init(
        project="science-visual-analysis",
        name=f"experiment_{date}",
        config={"date": date},
        reinit=True
    )

    artifact = wandb.Artifact(f"analysis_{date}", type="daily-experiment")

    # W&B Table to hold CSV data
    all_csv_tables = []

    for csv_path in data["csvs"]:
        print(f"[{date}] Adding CSV: {csv_path}")
        try:
            rel_name = os.path.relpath(csv_path, base_directory)
            artifact.add_file(csv_path, name=rel_name)

            df = pd.read_csv(csv_path)

            # Skip empty DataFrames
            if df.empty:
                print(f"⚠️ Skipping empty CSV: {csv_path}")
                continue

            # Log table to W&B
            table = wandb.Table(dataframe=df)
            table_name = f"csv_{os.path.basename(csv_path)}"
            wandb.log({table_name: table})
            print(f"✅ Logged table: {table_name}")

            # Try plotting first two numeric columns
            numeric_cols = df.select_dtypes(include='number').columns
            if len(numeric_cols) >= 2:
                plot_key = f"{os.path.basename(csv_path)}_plot"
                wandb.log({
                    plot_key: wandb.plot.line_series(
                        xs=df[numeric_cols[0]].tolist(),
                        ys=[df[numeric_cols[1]].tolist()],
                        keys=[numeric_cols[1]],
                        title=f"{plot_key}",
                        xname=numeric_cols[0]
                    )
                })
                print(f"📈 Logged plot: {plot_key}")

        except Exception as e:
            print(f"❌ Error adding CSV {csv_path}: {e}")


    for img_path in data["images"]:
        print(f"[{date}] Processing image: {img_path}")
        try:
            with open(img_path, "rb") as img_file:
                base64_image = base64.b64encode(img_file.read()).decode("utf-8")

            mime_type = {
                ".jpg": "image/jpeg",
                ".jpeg": "image/jpeg",
                ".png": "image/png",
                ".webp": "image/webp",
                ".gif": "image/gif"
            }.get(os.path.splitext(img_path)[1].lower(), "image/jpeg")

            data_url = f"data:{mime_type};base64,{base64_image}"

            response = client.chat.completions.create(
                model="gpt-4.5-preview-2025-02-27",
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": f"Interpret this image in relation to the following text: {reference_text}. Please provide a small very concise summary of what you observe in relation to background info."
                            },
                            {
                                "type": "image_url",
                                "image_url": {
                                    "url": data_url,
                                    "detail": "high"
                                }
                            }
                        ]
                    }
                ]
            )

            summary = response.choices[0].message.content
            print(f"→ GPT Summary: {summary}\n")

            wandb.log({
                "image": wandb.Image(img_path, caption=summary),
                "gpt_image_summary": summary
            })

            rel_name = os.path.relpath(img_path, base_directory)
            artifact.add_file(img_path, name=rel_name)

        except Exception as e:
            print(f"Error processing image {img_path}: {e}")

    # Upload files and finish
    run.log_artifact(artifact)
    run.finish()
