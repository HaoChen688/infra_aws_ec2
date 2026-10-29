document.getElementById('ping').addEventListener('click', () => {
  document.getElementById('out').textContent =
    'JS 正常，时间：' + new Date().toISOString();
});