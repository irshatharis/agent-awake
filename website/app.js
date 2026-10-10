const durationButtons = document.querySelectorAll('[data-duration]');
const title = document.getElementById('demo-title');
const reason = document.getElementById('demo-reason');
const caption = document.getElementById('demo-caption');
const protection = document.getElementById('demo-protection');
const icon = document.getElementById('demo-icon');
const agent = document.getElementById('demo-agent');
const panel = document.querySelector('.product-panel');
const indefinite = document.getElementById('demo-indefinite');
function selectSession(duration, selected) {
  title.textContent = 'Sleep prevented';
  reason.textContent = duration ? `Manual session · ${duration}` : 'Indefinite session';
  caption.textContent = duration ? `${duration} remaining` : 'Until you end it';
  protection.textContent = 'Display can sleep · lid protected';
  icon.textContent = '☀';
  agent.textContent = 'Working';
  panel.classList.remove('sleeping');
  indefinite.setAttribute('aria-pressed', String(!duration));
  durationButtons.forEach(button => {
    button.classList.toggle('selected', button === selected);
    button.setAttribute('aria-pressed', String(button === selected));
  });
}
durationButtons.forEach(button => button.addEventListener('click', () => selectSession(button.dataset.duration, button)));
indefinite.setAttribute('aria-pressed', 'false');
indefinite.addEventListener('click', () => selectSession(null, null));
document.getElementById('demo-sleep').addEventListener('click', () => {
  title.textContent = 'Sleep allowed';
  reason.textContent = 'Automatic mode paused';
  caption.textContent = 'Manual session ended · automatic mode paused';
  protection.textContent = 'Normal macOS sleep policy applies';
  icon.textContent = '☾';
  agent.textContent = 'Working';
  panel.classList.add('sleeping', 'is-paused');
  document.getElementById('demo-following').textContent = 'Paused until you resume';
  durationButtons.forEach(button => { button.classList.remove('selected'); button.setAttribute('aria-pressed', 'false'); });
  indefinite.setAttribute('aria-pressed', 'false');
});
