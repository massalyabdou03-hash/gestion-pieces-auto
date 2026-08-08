// =============================================================================
// A CONFIGURER : colle ici l'URL et la clé "anon public" de ton projet Supabase
// (Supabase Dashboard > Project Settings > API)
// =============================================================================
const SUPABASE_URL = "https://VOTRE-PROJET.supabase.co";
const SUPABASE_ANON_KEY = "VOTRE_CLE_ANON_PUBLIC";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
