/**
 * TrainMe Web Player
 * Static exercise plan viewer — clients open shared links from WhatsApp
 * to view their personalised training programmes.
 */

// ============================================================
// Configuration
// ============================================================

const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';

// ============================================================
// Mock Data — Remove when Supabase is connected
// ============================================================

const MOCK_PLAN = {
  id: 'test-plan-123',
  client_name: 'Karen',
  title: 'Shoulder Rehab Programme',
  created_at: '2026-04-16',
  exercises: [
    {
      position: 1,
      name: 'Scapular retraction with band',
      media_url: null,
      media_type: 'photo',
      reps: 12,
      sets: 3,
      hold_seconds: null,
      notes: 'Keep elbows close to body. Squeeze shoulder blades together at the end of each rep. Slow, controlled movement throughout.'
    },
    {
      position: 2,
      name: 'Prone Y-raise',
      media_url: null,
      media_type: 'video',
      reps: 10,
      sets: 3,
      hold_seconds: 2,
      notes: 'Lie face-down on the bench. Raise arms into a Y-shape with thumbs pointing up. Hold the top position for 2 seconds before lowering.'
    },
    {
      position: 3,
      name: 'Wall angel stretch',
      media_url: null,
      media_type: 'photo',
      reps: 8,
      sets: 2,
      hold_seconds: null,
      notes: 'Stand with back flat against the wall. Slide arms up and down keeping contact with the wall. If lower back arches, step feet further from the wall.'
    },
    {
      position: 4,
      name: 'Side-lying external rotation',
      media_url: null,
      media_type: 'photo',
      reps: 15,
      sets: 3,
      hold_seconds: null,
      notes: 'Place a rolled towel between your elbow and your side. Rotate forearm upward keeping the elbow pinned. Use a light weight (1-2 kg) or no weight initially.'
    },
    {
      position: 5,
      name: 'Thoracic spine foam roll',
      media_url: null,
      media_type: 'video',
      reps: null,
      sets: null,
      hold_seconds: 60,
      notes: 'Place foam roller across the upper back. Cross arms over chest. Slowly roll from mid-back to upper back. Breathe normally and pause on tender spots.'
    },
    {
      position: 6,
      name: 'Isometric shoulder flexion at wall',
      media_url: null,
      media_type: 'photo',
      reps: 5,
      sets: 3,
      hold_seconds: 10,
      notes: 'Stand facing the wall with fist at shoulder height. Push gently into the wall and hold. This should be pain-free \u2014 reduce pressure if any discomfort.'
    }
  ]
};

// ============================================================
// State
// ============================================================

let plan = null;
let currentIndex = 0;
let swipeState = { active: false, startX: 0, currentX: 0, startTime: 0 };

// ============================================================
// DOM references
// ============================================================

const $loading = document.getElementById('loading');
const $error = document.getElementById('error');
const $app = document.getElementById('app');
const $clientName = document.getElementById('client-name');
const $planTitle = document.getElementById('plan-title');
const $progress = document.getElementById('progress');
const $progressFill = document.getElementById('progress-fill');
const $cardViewport = document.getElementById('card-viewport');
const $cardTrack = document.getElementById('card-track');
const $navDots = document.getElementById('nav-dots');
const $btnPrev = document.getElementById('btn-prev');
const $btnNext = document.getElementById('btn-next');

// ============================================================
// Data fetching
// ============================================================

function getPlanIdFromURL() {
  const path = window.location.pathname;
  const match = path.match(/^\/p\/([a-zA-Z0-9_-]+)/);
  return match ? match[1] : null;
}

async function fetchPlan(planId) {
  // TODO_SUPABASE: Replace mock data fetch with real Supabase call
  // Example implementation:
  //
  // const response = await fetch(
  //   `${SUPABASE_URL}/rest/v1/plans?id=eq.${planId}&select=*,exercises(*)`,
  //   {
  //     headers: {
  //       'apikey': SUPABASE_ANON_KEY,
  //       'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
  //     }
  //   }
  // );
  //
  // if (!response.ok) throw new Error('Plan not found');
  // const data = await response.json();
  // if (!data.length) throw new Error('Plan not found');
  // return data[0];

  // Mock: simulate network delay then return mock data
  await new Promise(resolve => setTimeout(resolve, 600));
  return MOCK_PLAN;
}

// ============================================================
// Rendering
// ============================================================

function renderPlan() {
  $clientName.textContent = plan.client_name;
  $planTitle.textContent = plan.title;

  // Build navigation dots
  $navDots.innerHTML = plan.exercises
    .map((_, i) => `<div class="nav-dot${i === 0 ? ' is-active' : ''}" data-index="${i}"></div>`)
    .join('');

  // Build exercise cards
  $cardTrack.innerHTML = plan.exercises.map((ex, i) => buildCard(ex, i)).join('');

  // Add swipe hint on first card
  if (plan.exercises.length > 1) {
    const hint = document.createElement('div');
    hint.className = 'swipe-hint';
    hint.innerHTML = `
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <polyline points="15 18 9 12 15 6"></polyline>
      </svg>
      Swipe to navigate
    `;
    $cardViewport.appendChild(hint);
  }

  updateUI();
}

function buildCard(exercise, index) {
  const prescriptionPills = buildPrescription(exercise);
  const mediaHTML = buildMedia(exercise, index);

  return `
    <div class="exercise-card" data-index="${index}">
      <div class="card-inner">
        <div class="card-media">
          ${mediaHTML}
        </div>
        <div class="card-body">
          <div class="card-position">Exercise ${exercise.position}</div>
          <div class="card-exercise-name">${escapeHTML(exercise.name)}</div>
          ${prescriptionPills ? `<div class="card-prescription">${prescriptionPills}</div>` : ''}
          ${exercise.notes ? `<div class="card-notes">${escapeHTML(exercise.notes)}</div>` : ''}
        </div>
      </div>
    </div>
  `;
}

function buildMedia(exercise, index) {
  if (!exercise.media_url) {
    // Placeholder for exercises without media yet
    return `
      <div class="media-placeholder">
        <div class="media-placeholder-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            ${exercise.media_type === 'video'
              ? '<polygon points="5 3 19 12 5 21 5 3"></polygon>'
              : '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/>'
            }
          </svg>
        </div>
        <span class="media-placeholder-text">${exercise.media_type === 'video' ? 'Video' : 'Image'} coming soon</span>
      </div>
    `;
  }

  if (exercise.media_type === 'video') {
    return `
      <video
        id="video-${index}"
        src="${escapeHTML(exercise.media_url)}"
        playsinline
        loop
        muted
        preload="auto"
        poster=""
      ></video>
      <div class="video-play-overlay" data-video-index="${index}">
        <div class="play-button">
          <svg viewBox="0 0 24 24"><polygon points="6 3 20 12 6 21 6 3"></polygon></svg>
        </div>
      </div>
    `;
  }

  return `<img src="${escapeHTML(exercise.media_url)}" alt="${escapeHTML(exercise.name)}" loading="lazy">`;
}

function buildPrescription(exercise) {
  const pills = [];

  if (exercise.reps != null) {
    pills.push(`<span class="rx-pill">${exercise.reps} <span class="rx-pill-label">reps</span></span>`);
  }
  if (exercise.sets != null) {
    pills.push(`<span class="rx-pill">${exercise.sets} <span class="rx-pill-label">sets</span></span>`);
  }
  if (exercise.hold_seconds != null) {
    const label = exercise.hold_seconds >= 60
      ? `${Math.floor(exercise.hold_seconds / 60)}m ${exercise.hold_seconds % 60 ? exercise.hold_seconds % 60 + 's' : ''}`
      : `${exercise.hold_seconds}s`;
    pills.push(`<span class="rx-pill">${label} <span class="rx-pill-label">hold</span></span>`);
  }

  return pills.join('');
}

function escapeHTML(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// ============================================================
// Navigation
// ============================================================

function goTo(index) {
  if (index < 0 || index >= plan.exercises.length) return;

  // Pause any playing videos on current card
  pauseAllVideos();

  currentIndex = index;
  updateUI();
}

function goNext() {
  goTo(currentIndex + 1);
}

function goPrev() {
  goTo(currentIndex - 1);
}

function updateUI() {
  const total = plan.exercises.length;

  // Slide the track
  $cardTrack.style.transform = `translateX(-${currentIndex * 100}%)`;

  // Progress text
  $progress.textContent = `${currentIndex + 1} of ${total}`;

  // Progress bar
  $progressFill.style.width = `${((currentIndex + 1) / total) * 100}%`;

  // Nav buttons
  $btnPrev.disabled = currentIndex === 0;
  $btnNext.disabled = currentIndex === total - 1;

  // Dots
  const dots = $navDots.querySelectorAll('.nav-dot');
  dots.forEach((dot, i) => {
    dot.classList.toggle('is-active', i === currentIndex);
  });
}

// ============================================================
// Video Playback
// ============================================================

function handleVideoTap(e) {
  const overlay = e.target.closest('.video-play-overlay');
  if (!overlay) return;

  const videoIndex = parseInt(overlay.dataset.videoIndex, 10);
  const video = document.getElementById(`video-${videoIndex}`);
  if (!video) return;

  if (video.paused) {
    video.play();
    overlay.classList.add('is-hidden');
  } else {
    video.pause();
    overlay.classList.remove('is-hidden');
  }
}

function pauseAllVideos() {
  document.querySelectorAll('video').forEach(v => {
    v.pause();
  });
  document.querySelectorAll('.video-play-overlay').forEach(o => {
    o.classList.remove('is-hidden');
  });
}

// ============================================================
// Touch / Swipe Handling
// ============================================================

function onTouchStart(e) {
  if (e.touches.length > 1) return;

  swipeState.active = true;
  swipeState.startX = e.touches[0].clientX;
  swipeState.currentX = e.touches[0].clientX;
  swipeState.startTime = Date.now();

  $cardTrack.classList.add('is-swiping');
}

function onTouchMove(e) {
  if (!swipeState.active) return;

  swipeState.currentX = e.touches[0].clientX;
  const dx = swipeState.currentX - swipeState.startX;
  const viewportWidth = $cardViewport.offsetWidth;

  // Add resistance at edges
  let effectiveDx = dx;
  if ((currentIndex === 0 && dx > 0) || (currentIndex === plan.exercises.length - 1 && dx < 0)) {
    effectiveDx = dx * 0.25;
  }

  const offset = -(currentIndex * viewportWidth) + effectiveDx;
  $cardTrack.style.transform = `translateX(${offset}px)`;
}

function onTouchEnd() {
  if (!swipeState.active) return;
  swipeState.active = false;

  $cardTrack.classList.remove('is-swiping');

  const dx = swipeState.currentX - swipeState.startX;
  const dt = Date.now() - swipeState.startTime;
  const viewportWidth = $cardViewport.offsetWidth;
  const velocity = Math.abs(dx) / dt;

  // Threshold: 25% of viewport width or fast swipe
  const threshold = viewportWidth * 0.25;
  const isFastSwipe = velocity > 0.5 && Math.abs(dx) > 30;

  if ((Math.abs(dx) > threshold || isFastSwipe) && dx < 0) {
    goNext();
  } else if ((Math.abs(dx) > threshold || isFastSwipe) && dx > 0) {
    goPrev();
  } else {
    updateUI(); // snap back
  }
}

// ============================================================
// Keyboard Navigation
// ============================================================

function onKeyDown(e) {
  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
    e.preventDefault();
    goNext();
  } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
    e.preventDefault();
    goPrev();
  }
}

// ============================================================
// Service Worker Registration
// ============================================================

async function registerServiceWorker() {
  if ('serviceWorker' in navigator) {
    try {
      await navigator.serviceWorker.register('/sw.js');
    } catch (err) {
      console.warn('Service worker registration failed:', err);
    }
  }
}

// ============================================================
// Initialisation
// ============================================================

async function init() {
  registerServiceWorker();

  const planId = getPlanIdFromURL();

  try {
    plan = await fetchPlan(planId);

    if (!plan || !plan.exercises || plan.exercises.length === 0) {
      throw new Error('Empty plan');
    }

    // Sort exercises by position
    plan.exercises.sort((a, b) => a.position - b.position);

    // Render
    renderPlan();

    // Show app
    $loading.classList.add('fade-out');
    setTimeout(() => {
      $loading.hidden = true;
      $app.hidden = false;
    }, 250);

    // Bind events
    $btnNext.addEventListener('click', goNext);
    $btnPrev.addEventListener('click', goPrev);
    $cardViewport.addEventListener('touchstart', onTouchStart, { passive: true });
    $cardViewport.addEventListener('touchmove', onTouchMove, { passive: true });
    $cardViewport.addEventListener('touchend', onTouchEnd);
    $cardViewport.addEventListener('click', handleVideoTap);
    document.addEventListener('keydown', onKeyDown);

    // Dot navigation
    $navDots.addEventListener('click', (e) => {
      const dot = e.target.closest('.nav-dot');
      if (dot) goTo(parseInt(dot.dataset.index, 10));
    });

  } catch (err) {
    console.error('Failed to load plan:', err);
    $loading.hidden = true;
    $error.hidden = false;
  }
}

// Start the app
init();
