// Main Application Entry Point
const { createApp } = Vue
const { createPinia } = Pinia;
import BibframeApp from './components/App.js';

// Initialize Vue App
const pinia = createPinia();
const app = createApp(BibframeApp);

// Use Pinia
app.use(pinia);

// Mount the app
app.mount('#bibframe-app');
