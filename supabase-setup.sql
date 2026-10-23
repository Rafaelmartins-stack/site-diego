-- Execute este arquivo uma única vez no SQL Editor do Supabase.
-- Ele não apaga um conteúdo que já exista na linha id = 1.

insert into public.clinic_content (
  id,
  address,
  instagram,
  professional_name,
  professional_role,
  professional_description,
  professional_photo,
  appointment_message
)
values (
  1,
  'Rua Professor José de Souza, 227',
  '@diego.iamato',
  'Dr. Diego',
  'Nutricionista · CRN 00000',
  'Orientação para uma alimentação mais leve, rotina ativa e objetivos possíveis para a sua saúde.',
  'assets/dr-diego.png',
  'Olá, bom dia!, Gostaria de fazer uma consulta com o Dr. Diego.'
)
on conflict (id) do nothing;

-- Apenas pessoas cadastradas em staff_users poderão alterar o conteúdo.
create table if not exists public.staff_users (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.staff_users enable row level security;
alter table public.clinic_content enable row level security;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.staff_users
    where user_id = auth.uid()
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

-- Depois de criar a conta do funcionário em Authentication > Users,
-- substitua o UUID abaixo pelo UUID dessa pessoa e execute somente este comando:
-- insert into public.staff_users (user_id) values ('COLE-O-UUID-AQUI') on conflict do nothing;
