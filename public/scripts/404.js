async function loadRandomImage() {
  const img = document.getElementById('errorImage');

  try {
    const response = await fetch('/api/404-images');
    const data = await response.json();

    if (data.images && data.images.length > 0) {
      const randomImage = data.images[Math.floor(Math.random() * data.images.length)];
      img.src = `/404/${encodeURIComponent(randomImage)}`;
    } else {
      // Fallback if no images found
      img.style.display = 'none';
    }
  } catch (e) {
    console.error('Failed to load 404 images:', e);
    img.style.display = 'none';
  }
}

loadRandomImage();
