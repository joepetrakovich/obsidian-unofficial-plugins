document.querySelectorAll('a[data-url]').forEach(link => {
  link.addEventListener('click', async (e) => {
    e.preventDefault();
    const originalText = link.textContent;
    try {
      await navigator.clipboard.writeText(link.dataset.url);
      link.textContent = 'Copied!';
      setTimeout(() => link.textContent = originalText, 1500);
    } catch (err) {
      link.textContent = 'Failed';
      setTimeout(() => link.textContent = originalText, 1500);
    }
  });
});
