const panel = document.getElementById('panel');
const slider = document.getElementById('scaleSlider');
const value = document.getElementById('scaleValue');
const minScale = document.getElementById('minScale');
const maxScale = document.getElementById('maxScale');
const saveBtn = document.getElementById('saveBtn');
const resetBtn = document.getElementById('resetBtn');
const closeBtn = document.getElementById('closeBtn');

const resourceName = typeof GetParentResourceName === 'function'
    ? GetParentResourceName()
    : 'crimson-pedscale';

let currentScale = 1.0;

function post(action, data = {}) {
    return fetch(`https://${resourceName}/${action}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data)
    });
}

function paintSlider() {
    const min = Number(slider.min);
    const max = Number(slider.max);
    const raw = Number(slider.value);
    const percent = ((raw - min) / (max - min)) * 100;
    slider.style.background = `linear-gradient(90deg, #ef334d ${percent}%, rgba(255, 255, 255, 0.18) ${percent}%)`;
}

function setScale(scale, preview = true) {
    currentScale = Number(scale);
    slider.value = Math.round(currentScale * 100);
    value.textContent = currentScale.toFixed(2);
    paintSlider();
    if (preview) {
        post('preview', { scale: currentScale });
    }
}

slider.addEventListener('input', () => {
    setScale(Number(slider.value) / 100);
});

saveBtn.addEventListener('click', () => {
    post('save', { scale: currentScale });
});

resetBtn.addEventListener('click', () => {
    setScale(1.0, false);
    post('reset');
});

closeBtn.addEventListener('click', () => {
    post('close');
});

window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
        post('close');
    }
});

window.addEventListener('message', (event) => {
    const data = event.data || {};
    if (data.action === 'open') {
        const min = Number(data.min ?? 0.87);
        const max = Number(data.max ?? 1.10);
        const step = Number(data.step ?? 0.01);
        slider.min = Math.round(min * 100);
        slider.max = Math.round(max * 100);
        slider.step = Math.max(1, Math.round(step * 100));
        minScale.textContent = min.toFixed(2);
        maxScale.textContent = max.toFixed(2);
        setScale(Number(data.scale ?? 1.0), false);
        panel.classList.remove('hidden');
    }

    if (data.action === 'close') {
        panel.classList.add('hidden');
    }
});
