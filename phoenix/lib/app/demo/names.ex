defmodule App.Demo.Names do
  @moduledoc """
  Name lists for synthetic people (`App.Demo`). Ukrainian names are
  transliterated so generated emails stay ASCII; only they get a
  patronymic, which is how the naming convention works.
  """

  @uk_male ~w(Andrii Bohdan Dmytro Ivan Mykola Oleksandr Petro Serhii Taras Vasyl Yurii Volodymyr)
  @uk_female ~w(Anna Iryna Kateryna Mariia Nataliia Oksana Olena Sofiia Tetiana Yuliia)
  @uk_family ~w(Bondarenko Boiko Hrytsenko Kovalenko Kravchenko Lysenko Melnyk Moroz Oliinyk
                Pavlenko Savchenko Shevchenko Tkachenko Kovalchuk Rudenko Marchenko)
  @uk_patronymic_male ~w(Andriiovych Ivanovych Mykolaiovych Oleksandrovych Petrovych Serhiiovych)
  @uk_patronymic_female ~w(Andriivna Ivanivna Mykolaivna Oleksandrivna Petrivna Serhiivna)

  @en_male ~w(James John Robert Michael William David Thomas Daniel Matthew Andrew)
  @en_female ~w(Mary Patricia Jennifer Linda Elizabeth Sarah Emily Laura Rachel Hannah)
  @en_family ~w(Smith Johnson Williams Brown Jones Miller Davis Wilson Taylor Clark Walker Hall)

  @fr_male ~w(Jean Pierre Louis Nicolas Julien Antoine Mathieu Thomas Hugo Lucas)
  @fr_female ~w(Marie Camille Claire Julie Chloe Manon Lea Sophie Isabelle Elise)
  @fr_family ~w(Martin Bernard Dubois Durand Lefebvre Moreau Laurent Simon Michel Garnier Roux)

  @doc """
  A name for `sex` (`:male` / `:female`) from `origin` (`:uk`, `:en`,
  `:fr`): `%{given_name, family_name, patronymic, country}`. Uses the
  caller's `:rand` state, so a seeded caller gets repeatable names.
  """
  @spec pick(:uk | :en | :fr, :male | :female) :: map()
  def pick(:uk, sex) do
    {given, patronymics} =
      if sex == :male,
        do: {@uk_male, @uk_patronymic_male},
        else: {@uk_female, @uk_patronymic_female}

    %{
      given_name: Enum.random(given),
      family_name: Enum.random(@uk_family),
      patronymic: Enum.random(patronymics),
      country: "UA"
    }
  end

  def pick(:en, sex) do
    %{
      given_name: Enum.random(if sex == :male, do: @en_male, else: @en_female),
      family_name: Enum.random(@en_family),
      patronymic: nil,
      country: "GB"
    }
  end

  def pick(:fr, sex) do
    %{
      given_name: Enum.random(if sex == :male, do: @fr_male, else: @fr_female),
      family_name: Enum.random(@fr_family),
      patronymic: nil,
      country: "FR"
    }
  end
end
