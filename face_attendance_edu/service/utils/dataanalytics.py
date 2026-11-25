import pandas as pd
from openpyxl import load_workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter


class Dataanalytics:
    FEUILLE_JOURNALIERE = "Présence journalière"
    FEUILLE_RESUME = "Résumé"

    # Colonnes de la vue daily_presence_report -> en-têtes français du fichier Excel
    COLONNES = {
        "student_name": "Étudiant",
        "username": "Identifiant",
        "classroom_name": "Classe",
        "department_name": "Département",
        "attendance_date": "Date",
        "morning_hours": "Matin (h)",
        "afternoon_hours": "Après-midi (h)",
        "total_hours": "Total (h)",
        "expected_morning_hours": "Matin attendu (h)",
        "expected_afternoon_hours": "Après-midi attendu (h)",
        "expected_total_hours": "Total attendu (h)",
        "morning_attendance_rate": "Taux matin (%)",
        "afternoon_attendance_rate": "Taux après-midi (%)",
        "total_attendance_rate": "Taux total (%)",
        "total_late_minutes": "Retard (min)",
        "penalty_count": "Pénalités",
    }

    COLONNES_NOMBRES = [
        "Matin (h)", "Après-midi (h)", "Total (h)",
        "Matin attendu (h)", "Après-midi attendu (h)", "Total attendu (h)",
        "Taux matin (%)", "Taux après-midi (%)", "Taux total (%)",
        "Retard (min)", "Pénalités",
    ]

    COULEURS_STATUT = {
        "Absent": "F8CBAD",               # rouge clair
        "Absent le matin": "FFE699",      # jaune clair
        "Absent l'après-midi": "FFE699",
    }

    # ------------------------------------------------------------------
    # Point d'entrée
    # ------------------------------------------------------------------
    @staticmethod
    def get_excel(data: list[dict], file_path: str) -> str:
        """Construit le classeur de présence et retourne le chemin du fichier."""
        if not data:
            raise ValueError("Aucune ligne de présence à exporter")

        df = Dataanalytics._preparer_donnees(data)

        # 1) Feuille « Présence journalière » écrite par pandas
        with pd.ExcelWriter(file_path, engine="openpyxl") as writer:
            df.to_excel(writer, sheet_name=Dataanalytics.FEUILLE_JOURNALIERE, index=False)

        # 2) Résumé (formules) + mise en forme, en une seule ouverture du fichier
        wb = load_workbook(file_path)
        Dataanalytics._ajouter_resume(wb, df)
        Dataanalytics._mettre_en_forme(wb)
        wb.save(file_path)

        return file_path

    # ------------------------------------------------------------------
    # Préparation des données
    # ------------------------------------------------------------------
    @staticmethod
    def _preparer_donnees(data: list[dict]) -> pd.DataFrame:
        df = pd.DataFrame(data)

        colonnes = [c for c in Dataanalytics.COLONNES if c in df.columns]
        df = df[colonnes].rename(columns=Dataanalytics.COLONNES)

        df["Date"] = pd.to_datetime(df["Date"]).dt.date

        # Les jours d'absence peuvent contenir des valeurs vides : on les remplace par 0
        for col in Dataanalytics.COLONNES_NOMBRES:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0).round(2)

        # Colonne « Statut » placée juste après la date
        df.insert(
            df.columns.get_loc("Date") + 1,
            "Statut",
            df.apply(Dataanalytics._calculer_statut, axis=1),
        )

        return df.sort_values(["Étudiant", "Date"]).reset_index(drop=True)

    @staticmethod
    def _calculer_statut(ligne: pd.Series) -> str:
        """Présent, absent toute la journée, ou absent sur une seule session."""
        absent_matin = ligne["Matin attendu (h)"] > 0 and ligne["Matin (h)"] == 0
        absent_apres_midi = ligne["Après-midi attendu (h)"] > 0 and ligne["Après-midi (h)"] == 0

        if absent_matin and absent_apres_midi:
            return "Absent"
        if absent_matin:
            return "Absent le matin"
        if absent_apres_midi:
            return "Absent l'après-midi"
        return "Présent"

    # ------------------------------------------------------------------
    # Feuille « Résumé » (une ligne par étudiant, calculée par formules Excel)
    # ------------------------------------------------------------------
    @staticmethod
    def _ajouter_resume(wb, df: pd.DataFrame):
        journalier = wb[Dataanalytics.FEUILLE_JOURNALIERE]
        resume = wb.create_sheet(Dataanalytics.FEUILLE_RESUME)
        derniere_ligne = journalier.max_row  # l'en-tête est la ligne 1

        def plage(nom_colonne: str) -> str:
            lettre = get_column_letter(df.columns.get_loc(nom_colonne) + 1)
            return f"'{Dataanalytics.FEUILLE_JOURNALIERE}'!${lettre}$2:${lettre}${derniere_ligne}"

        etudiants = plage("Étudiant")
        statuts = plage("Statut")

        resume.append([
            "Étudiant", "Jours de cours", "Jours présents", "Jours absents",
            "Heures totales", "Heures attendues", "Taux moyen (%)",
            "Retard total (min)", "Total pénalités",
        ])

        for i, nom in enumerate(df["Étudiant"].drop_duplicates(), start=2):
            ref = f"A{i}"
            resume.append([
                nom,
                f"=COUNTIF({etudiants},{ref})",
                f"=B{i}-D{i}",
                f'=COUNTIFS({etudiants},{ref},{statuts},"Absent")',
                f"=SUMIF({etudiants},{ref},{plage('Total (h)')})",
                f"=SUMIF({etudiants},{ref},{plage('Total attendu (h)')})",
                f"=ROUND(AVERAGEIF({etudiants},{ref},{plage('Taux total (%)')}),2)",
                f"=SUMIF({etudiants},{ref},{plage('Retard (min)')})",
                f"=SUMIF({etudiants},{ref},{plage('Pénalités')})",
            ])

    # ------------------------------------------------------------------
    # Mise en forme
    # ------------------------------------------------------------------
    @staticmethod
    def _mettre_en_forme(wb):
        police_entete = Font(name="Arial", bold=True, color="FFFFFF")
        fond_entete = PatternFill("solid", fgColor="4472C4")

        for ws in wb.worksheets:
            # En-têtes
            for cellule in ws[1]:
                cellule.font = police_entete
                cellule.fill = fond_entete
                cellule.alignment = Alignment(horizontal="center")

            # Police des données
            for ligne in ws.iter_rows(min_row=2):
                for cellule in ligne:
                    cellule.font = Font(name="Arial")

            # Largeur des colonnes selon le contenu (entre 10 et 40)
            for colonne in ws.columns:
                longueur = max(
                    (len(str(c.value)) for c in colonne if c.value is not None),
                    default=0,
                )
                ws.column_dimensions[colonne[0].column_letter].width = min(max(longueur + 2, 10), 40)

            ws.freeze_panes = "A2"
            ws.auto_filter.ref = ws.dimensions

        Dataanalytics._formater_feuille_journaliere(wb[Dataanalytics.FEUILLE_JOURNALIERE])

    @staticmethod
    def _formater_feuille_journaliere(ws):
        entetes = [c.value for c in ws[1]]
        col_date = entetes.index("Date") + 1
        col_statut = entetes.index("Statut") + 1

        for ligne in range(2, ws.max_row + 1):
            ws.cell(row=ligne, column=col_date).number_format = "DD/MM/YYYY"

            cellule_statut = ws.cell(row=ligne, column=col_statut)
            couleur = Dataanalytics.COULEURS_STATUT.get(cellule_statut.value)
            if couleur:
                cellule_statut.fill = PatternFill("solid", fgColor=couleur)