curl -X POST -H "Content-Type: application/json" -d '{
    "reference_number": "R-120001",
    "transdate": "07-07-2023",
    "description": "Test Description",
    "currency": "EUR",
    "exchangerate": "0",
    "notes": "some-notes",
    "department": "",
    "LINES": [
        {
            "debit": "242",
            "credit": "",
            "tax_account": "",
            "tax_amount": "",
            "cleared": "",
            "accno": "0010"
        },
        {
            "debit": "",
            "credit": "2422",
            "tax_account": "",
            "tax_amount": "",
            "cleared": "",
            "accno": "0011"
        }
    ]
}' http://u22.mnapk.com/api/index.pl/ledger28/gl_transaction