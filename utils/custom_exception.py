import sys

class CustomException(Exception):
    def __init__(self, message: str, error_detail: sys):
        super().__init__(message)
        self.error_detail = error_detail

    def __str__(self):
        return f"CustomException: {self.args[0]} | Error Detail: {self.error_detail}"
    
    @staticmethod
    def get_detailed_error_message(message, error_detail):
        _, _, exc_tb = sys.exc_info()
        file_name = exc_tb.tb_frame.f_code.co_filename if exc_tb else "Unknown File"
        line_number = exc_tb.tb_lineno if exc_tb else "Unknown Line"
        return f"{message} | Error: {error_detail} | File: {file_name} | Line: {line_number}"

    def __str__(self):
        return self.error_message