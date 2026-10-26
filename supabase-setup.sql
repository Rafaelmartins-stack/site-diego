-- Execute este arquivo uma única vez no SQL Editor do Supabase.
-- Ele não apaga um conteúdo que já exista na linha id = 1.

alter table public.clinic_content
add column if not exists phone text;

-- Conteúdos visuais alterados diretamente no modo funcionário.
alter table public.clinic_content
add column if not exists page_content jsonb not null default '{}'::jsonb;

alter table public.clinic_content
add column if not exists site_images jsonb not null default '{}'::jsonb;

insert into public.clinic_content (
  id,
  address,
  instagram,
  professional_name,
  professional_role,
  professional_description,
  professional_photo,
  appointment_message,
  phone
)
values (
  1,
  'Rua Professor José de Souza, 227',
  '@diego.iamato',
  'Dr. Diego',
  'Nutricionista · CRN 00000',
  'Orientação para uma alimentação mais leve, rotina ativa e objetivos possíveis para a sua saúde.',
  'assets/dr-diego.png',
  'Olá, bom dia!, Gostaria de fazer uma consulta com o Dr. Diego.',
  '5511999822322'
)
on conflict (id) do nothing;

-- Somente estes dois e-mails autenticados poderão alterar o conteúdo.
alter table public.clinic_content enable row level security;

create or replace function public.is_staff()
returns boolean
language sql
stable
set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'familiarafael00@gmail.com',
    'r.martins140111@gmail.com'
  );
$$;

drop policy if exists "Visitors can read clinic content" on public.clinic_content;
create policy "Visitors can read clinic content"
on public.clinic_content
for select
to anon, authenticated
using (true);

drop policy if exists "Staff can update clinic content" on public.clinic_content;
create policy "Staff can update clinic content"
on public.clinic_content
for update
to authenticated
using (public.is_staff())
with check (public.is_staff());

-- Habilita os eventos UPDATE para atualizar todas as abas abertas em tempo real.
do $$
begin
  alter publication supabase_realtime add table public.clinic_content;
exception
  when duplicate_object then null;
end;
$$;

-- Crie em Authentication > Users exatamente estas duas contas, ambas com a senha definida pela equipe:
-- familiarafael00@gmail.com
-- r.martins140111@gmail.com

-- ============================================================================
-- PORTAL DO PACIENTE E AGENDA
-- Execute também esta parte no SQL Editor para ativar o modo agenda.
-- As regras abaixo protegem os dados: cada paciente lê somente o próprio perfil,
-- consultas e orientações. Apenas a equipe pode consultar todos os pacientes e
-- registrar orientações clínicas.
--
-- Para que uma conta nova entre imediatamente no portal, desative a confirmação
-- de e-mail no painel do Supabase: Authentication > Providers > Email >
-- "Confirm email". Essa opção é de autenticação e não pode ser alterada por SQL.
-- ============================================================================

create table if not exists public.patient_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patient_profiles(id) on delete cascade,
  scheduled_at timestamptz not null,
  duration_minutes smallint not null default 60 check (duration_minutes between 15 and 240),
  status text not null default 'requested' check (status in ('requested', 'confirmed', 'completed', 'cancelled')),
  patient_message text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Evita duas consultas no mesmo horário.
create unique index if not exists appointments_unique_start
on public.appointments (scheduled_at);

create table if not exists public.consultation_notes (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patient_profiles(id) on delete cascade,
  consultation_summary text not null,
  training_plan text not null default '',
  diet_plan text not null default '',
  recorded_by uuid references auth.users(id) on delete set null,
  recorded_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    length(trim(consultation_summary)) > 0
    or length(trim(training_plan)) > 0
    or length(trim(diet_plan)) > 0
  )
);

-- Cria o perfil do paciente quando ele conclui o cadastro no site.
-- As contas da equipe não entram como pacientes.
create or replace function public.create_patient_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(coalesce(new.email, '')) in (
    'familiarafael00@gmail.com',
    'r.martins140111@gmail.com'
  ) then
    return new;
  end if;

  insert into public.patient_profiles (id, full_name, email)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(new.email, ''), '@', 1), 'Paciente'),
    coalesce(new.email, '')
  )
  on conflict (id) do update
  set email = excluded.email,
      updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_patient_profile on auth.users;
create trigger on_auth_user_created_patient_profile
after insert on auth.users
for each row execute procedure public.create_patient_profile_for_new_user();

-- Também prepara perfis para contas de pacientes que já existirem.
insert into public.patient_profiles (id, full_name, email)
select
  users.id,
  coalesce(nullif(trim(users.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(users.email, ''), '@', 1), 'Paciente'),
  coalesce(users.email, '')
from auth.users as users
where lower(coalesce(users.email, '')) not in (
  'familiarafael00@gmail.com',
  'r.martins140111@gmail.com'
)
on conflict (id) do nothing;

alter table public.patient_profiles enable row level security;
alter table public.appointments enable row level security;
alter table public.consultation_notes enable row level security;

grant select, insert, update, delete
on public.patient_profiles, public.appointments, public.consultation_notes
to authenticated;

drop policy if exists "Patients or staff can read profiles" on public.patient_profiles;
create policy "Patients or staff can read profiles"
on public.patient_profiles for select to authenticated
using (auth.uid() = id or public.is_staff());

drop policy if exists "Patients or staff can create profiles" on public.patient_profiles;
create policy "Patients or staff can create profiles"
on public.patient_profiles for insert to authenticated
with check (auth.uid() = id or public.is_staff());

drop policy if exists "Patients or staff can update profiles" on public.patient_profiles;
create policy "Patients or staff can update profiles"
on public.patient_profiles for update to authenticated
using (auth.uid() = id or public.is_staff())
with check (auth.uid() = id or public.is_staff());

drop policy if exists "Patients or staff can read appointments" on public.appointments;
create policy "Patients or staff can read appointments"
on public.appointments for select to authenticated
using (auth.uid() = patient_id or public.is_staff());

drop policy if exists "Patients can request appointments" on public.appointments;
create policy "Patients can request appointments"
on public.appointments for insert to authenticated
with check (
  (auth.uid() = patient_id and status = 'requested')
  or public.is_staff()
);

drop policy if exists "Staff can update appointments" on public.appointments;
create policy "Staff can update appointments"
on public.appointments for update to authenticated
using (public.is_staff())
with check (public.is_staff());

drop policy if exists "Staff can delete appointments" on public.appointments;
create policy "Staff can delete appointments"
on public.appointments for delete to authenticated
using (public.is_staff());

drop policy if exists "Patients or staff can read consultation notes" on public.consultation_notes;
create policy "Patients or staff can read consultation notes"
on public.consultation_notes for select to authenticated
using (auth.uid() = patient_id or public.is_staff());

drop policy if exists "Staff can create consultation notes" on public.consultation_notes;
create policy "Staff can create consultation notes"
on public.consultation_notes for insert to authenticated
with check (public.is_staff());

drop policy if exists "Staff can update consultation notes" on public.consultation_notes;
create policy "Staff can update consultation notes"
on public.consultation_notes for update to authenticated
using (public.is_staff())
with check (public.is_staff());

drop policy if exists "Staff can delete consultation notes" on public.consultation_notes;
create policy "Staff can delete consultation notes"
on public.consultation_notes for delete to authenticated
using (public.is_staff());

-- Atualização ao vivo do portal e da agenda em abas abertas.
do $$
begin
  alter publication supabase_realtime add table public.patient_profiles;
exception when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.appointments;
exception when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.consultation_notes;
exception when duplicate_object then null;
end;
$$;

-- ============================================================================
-- DISPONIBILIDADE DE HORÁRIOS
-- Execute novamente este arquivo no SQL Editor após atualizar o site.
-- A equipe abre a agenda por dia ou por período; pacientes só enxergam os
-- horários livres e o banco também impede solicitações fora desses horários.
-- ============================================================================

create table if not exists public.appointment_availability (
  id uuid primary key default gen_random_uuid(),
  available_date date not null unique,
  start_time time not null,
  end_time time not null,
  slot_minutes smallint not null default 60 check (slot_minutes in (30, 45, 60, 90)),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(),
  check (end_time > start_time)
);

alter table public.appointment_availability enable row level security;

grant select, insert, update, delete
on public.appointment_availability
to authenticated;

drop policy if exists "Authenticated users can read appointment availability" on public.appointment_availability;
create policy "Authenticated users can read appointment availability"
on public.appointment_availability for select to authenticated
using (true);

drop policy if exists "Staff can create appointment availability" on public.appointment_availability;
create policy "Staff can create appointment availability"
on public.appointment_availability for insert to authenticated
with check (public.is_staff());

drop policy if exists "Staff can update appointment availability" on public.appointment_availability;
create policy "Staff can update appointment availability"
on public.appointment_availability for update to authenticated
using (public.is_staff())
with check (public.is_staff());

drop policy if exists "Staff can delete appointment availability" on public.appointment_availability;
create policy "Staff can delete appointment availability"
on public.appointment_availability for delete to authenticated
using (public.is_staff());

-- Confere, no fuso de São Paulo, se uma consulta pertence a um horário liberado.
create or replace function public.appointment_matches_availability(
  p_scheduled_at timestamptz,
  p_duration_minutes smallint
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with local_slot as (
    select p_scheduled_at at time zone 'America/Sao_Paulo' as starts_at
  )
  select exists (
    select 1
    from public.appointment_availability as availability
    cross join local_slot
    where availability.available_date = local_slot.starts_at::date
      and availability.slot_minutes = p_duration_minutes
      and local_slot.starts_at >= availability.available_date + availability.start_time
      and local_slot.starts_at + make_interval(mins => p_duration_minutes::integer) <= availability.available_date + availability.end_time
      and mod(
        extract(epoch from (local_slot.starts_at - (availability.available_date + availability.start_time)))::bigint,
        availability.slot_minutes::bigint * 60
      ) = 0
  );
$$;

revoke all on function public.appointment_matches_availability(timestamptz, smallint) from public;
grant execute on function public.appointment_matches_availability(timestamptz, smallint) to authenticated;

-- Entrega somente horários livres, sem expor dados ou compromissos de outros pacientes.
create or replace function public.get_available_appointment_slots(target_date date)
returns table (start_time time, duration_minutes smallint)
language sql
stable
security definer
set search_path = public
as $$
  with generated_slots as (
    select
      availability.available_date + availability.start_time + make_interval(mins => availability.slot_minutes::integer * slot_number) as slot_starts_at,
      availability.slot_minutes
    from public.appointment_availability as availability
    cross join lateral generate_series(
      0,
      floor(
        extract(epoch from ((availability.available_date + availability.end_time) - (availability.available_date + availability.start_time)))
        / (availability.slot_minutes::integer * 60)
      )::integer - 1
    ) as slot_number
    where availability.available_date = target_date
  )
  select generated_slots.slot_starts_at::time, generated_slots.slot_minutes
  from generated_slots
  where not exists (
    select 1
    from public.appointments as appointment
    where appointment.status <> 'cancelled'
      and tstzrange(
        appointment.scheduled_at,
        appointment.scheduled_at + make_interval(mins => appointment.duration_minutes::integer),
        '[)'
      ) && tstzrange(
        generated_slots.slot_starts_at at time zone 'America/Sao_Paulo',
        (generated_slots.slot_starts_at + make_interval(mins => generated_slots.slot_minutes::integer)) at time zone 'America/Sao_Paulo',
        '[)'
      )
  )
  order by generated_slots.slot_starts_at;
$$;

revoke all on function public.get_available_appointment_slots(date) from public;
grant execute on function public.get_available_appointment_slots(date) to authenticated;

-- Recria a regra de criação: clientes só podem solicitar um slot aberto e livre.
drop policy if exists "Patients can request appointments" on public.appointments;
create policy "Patients can request appointments"
on public.appointments for insert to authenticated
with check (
  public.appointment_matches_availability(scheduled_at, duration_minutes)
  and (
    public.is_staff()
    or (auth.uid() = patient_id and status = 'requested')
  )
);

do $$
begin
  alter publication supabase_realtime add table public.appointment_availability;
exception when duplicate_object then null;
end;
$$;
