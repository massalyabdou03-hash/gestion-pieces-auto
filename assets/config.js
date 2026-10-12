// Connexion à Supabase (Dashboard > Project Settings > API).
// La clé "publishable" est faite pour être visible dans le navigateur : la protection des
// données repose sur les règles RLS de la base (voir supabase/migrations), pas sur le secret de cette clé.
// Ne jamais mettre ici la clé "service_role".
const SUPABASE_URL = "https://firytchonwlvthschvow.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_Idtn_tErn8sJxXNC3WEAkA_9vGfT31L";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
