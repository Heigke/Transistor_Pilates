import os
import base64
from dotenv import load_dotenv
from openai import OpenAI

# Load environment variables from .env file
load_dotenv()

# Get the API key from environment variable
api_key = os.getenv("OPENAI_API_KEY")

# Initialize the OpenAI client with the key
client = OpenAI(api_key=api_key)


# Text to interpret image against
reference_text = "texttext"
with open("background.txt", "r") as file:
    reference_text = file.read()
# Folder containing your images
base_directory = "."  # or specify path explicitly

# Supported image extensions
image_extensions = (".jpg", ".jpeg", ".png", ".webp", ".gif")

# Walk through directories
for root, dirs, files in os.walk(base_directory):
    # Skip 'first_old' folder
    if "first_old" in root.split(os.sep):
        continue

    for file in files:
        if file.lower().endswith(image_extensions):
            image_path = os.path.join(root, file)
            print(f"Processing: {image_path}")

            # Encode the image to base64
            with open(image_path, "rb") as image_file:
                base64_image = base64.b64encode(image_file.read()).decode("utf-8")

            # Determine image MIME type
            ext = os.path.splitext(file)[1].lower()
            mime_type = {
                ".jpg": "image/jpeg",
                ".jpeg": "image/jpeg",
                ".png": "image/png",
                ".webp": "image/webp",
                ".gif": "image/gif"
            }.get(ext, "image/jpeg")

            data_url = f"data:{mime_type};base64,{base64_image}"

            # Send to GPT-4.5
            try:
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

                print("Result:")
                print(response.choices[0].message.content)
                print("=" * 80)

            except Exception as e:
                print(f"Error processing {image_path}: {e}")
