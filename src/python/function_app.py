import azure.functions as func
import logging

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

@app.route(route="csvtojson")
def csvtojson(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Python HTTP trigger function processed a request.')

    #Todo - convert csv from HTTP input body to json
    #Todo - return json as HTTP response
    jsonResponse = {"test": "testcontent"}
    return func.HttpResponse(jsonResponse, mimetype="application/json")
